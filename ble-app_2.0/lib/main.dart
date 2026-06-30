import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:async';
import 'dart:math';
import 'dart:convert';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'native_sms_service.dart'; // ⚠️ adjust path if you place this file in a subfolder
 
 
class EmergencyContact {
  final String id;
  final String name;
  final String phone;
  final String relationship;
 
  EmergencyContact({
    required this.id,
    required this.name,
    required this.phone,
    this.relationship = '',
  });
 
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'phone': phone,
        'relationship': relationship,
      };
 
  factory EmergencyContact.fromJson(Map<String, dynamic> json) =>
      EmergencyContact(
        id: json['id'],
        name: json['name'],
        phone: json['phone'],
        relationship: json['relationship'] ?? '',
      );
}
 
// ─────────────────────────────────────────────
//  CONTACT STORE
// ─────────────────────────────────────────────
class ContactStore {
  static const _key = 'emergency_contacts';
 
  static Future<List<EmergencyContact>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? [];
    return raw
        .map((e) => EmergencyContact.fromJson(jsonDecode(e)))
        .toList();
  }
 
  static Future<void> save(List<EmergencyContact> contacts) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _key,
      contacts.map((e) => jsonEncode(e.toJson())).toList(),
    );
  }
}
 
// ─────────────────────────────────────────────
//  GLOBAL FLAGS
// ─────────────────────────────────────────────
bool isReconnecting = false;
 
void main() {
  runApp(const MyApp());
}
 
class MyApp extends StatelessWidget {
  const MyApp({super.key});
 
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AegisLink',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A0E1A),
        cardColor: const Color(0xFF111827),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF111827),
          foregroundColor: Colors.white,
          elevation: 0,
        ),
      ),
      home: const BleHome(),
    );
  }
}
 
// ─────────────────────────────────────────────
//  MAIN WIDGET
// ─────────────────────────────────────────────
class BleHome extends StatefulWidget {
  const BleHome({super.key});
 
  @override
  State<BleHome> createState() => _BleHomeState();
}
 
class _BleHomeState extends State<BleHome> with SingleTickerProviderStateMixin {
  // ── BLE ──────────────────────────────────
  String status = "Waiting...";
  BluetoothDevice? espDevice;
  BluetoothCharacteristic? notifyChar;
  String rawBleData = "--";
 
  // ── MPU6050 ──────────────────────────────
  double accX = 0, accY = 0, accZ = 0;
  double gyroX = 0, gyroY = 0, gyroZ = 0;
  double mpuTemp = 0;
  double accMagnitude = 0;
 
  // ── ESP32 classifier label ───────────────
  // ⚠️ Set once your ESP32 firmware sends the Random Forest class
  // as an 8th CSV field, e.g. "NORMAL" / "DISTURBANCE" / "CRASH".
  // Until then this stays null and the magnitude fallback is used.
  String? lastEsp32Label;
 
  // ── GPS ──────────────────────────────────
  StreamSubscription<Position>? positionStream;
  double currentLat = 0;
  double currentLng = 0;
  double currentSpeed = 0; // m/s
 
  // ── Geo-fence ────────────────────────────
  final double safeLat = 13.0827;
  final double safeLng = 80.2707;
  final double safeRadius = 500; // metres
  String geoStatus = "✅ Inside Safe Zone";
 
  // ── Stationary detection ─────────────────
  DateTime? lastMovementTime;
  double previousLat = 0;
  double previousLng = 0;
  String movementStatus = "Moving";
 
  // ── Trail ────────────────────────────────
  final List<LatLng> trailPoints = [];
 
  // ── Alert log ────────────────────────────
  final List<String> alertLog = [];
 
  // ── Contacts ─────────────────────────────
  List<EmergencyContact> _contacts = [];
 
  // ── Tabs ─────────────────────────────────
  late TabController _tabController;
 
  // ── Map controller ───────────────────────
  final MapController _mapController = MapController();
 
  // ── Crash cooldown ───────────────────────
  DateTime? _lastSosTrigger;
 
  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _loadContacts();
    initBle();
    startLocationTracking();
  }
 
  @override
  void dispose() {
    positionStream?.cancel();
    _tabController.dispose();
    super.dispose();
  }
 
  // ─────────────────────────────────────────
  //  CONTACTS
  // ─────────────────────────────────────────
  Future<void> _loadContacts() async {
    final contacts = await ContactStore.load();
    if (mounted) setState(() => _contacts = contacts);
  }
 
  Future<void> _saveContacts() async {
    await ContactStore.save(_contacts);
  }
 
  // ─────────────────────────────────────────
  //  BLE – SCAN
  // ─────────────────────────────────────────
  Future<void> initBle() async {
    await Permission.locationWhenInUse.request();
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();
    await Permission.sms.request(); // ← required once for native SMS to work
 
    if (!(await FlutterBluePlus.isOn)) {
      setState(() => status = "Bluetooth is OFF");
      return;
    }
 
    setState(() => status = "Scanning...");
 
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
 
    FlutterBluePlus.scanResults.listen((results) async {
      for (var r in results) {
        // ⚠️ Change "ESP32_MPU6050" to your actual ESP32 advertised name
        if (r.device.platformName == "ESP32_MPU6050") {
          await FlutterBluePlus.stopScan();
          espDevice = r.device;
          setState(() => status = "Connecting...");
          await connectToEsp32();
          return;
        }
      }
    });
  }
 
  // ─────────────────────────────────────────
  //  BLE – CONNECT & SUBSCRIBE
  // ─────────────────────────────────────────
  Future<void> connectToEsp32() async {
    if (espDevice == null) return;
 
    try {
      await espDevice!.connect(autoConnect: false);
    } catch (e) {
      setState(() => status = "Connect error: $e");
      return;
    }
 
    setState(() => status = "Connected ✅");
    isReconnecting = false;
 
    espDevice!.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected && !isReconnecting) {
        isReconnecting = true;
        setState(() => status = "Reconnecting...");
        Future.delayed(const Duration(seconds: 3), () => initBle());
      }
    });
 
    List<BluetoothService> services = await espDevice!.discoverServices();
 
    for (var service in services) {
      for (var char in service.characteristics) {
        if (char.properties.notify) {
          notifyChar = char;
          await notifyChar!.setNotifyValue(true);
 
          notifyChar!.onValueReceived.listen((value) async {
            if (!mounted) return;
            final data = String.fromCharCodes(value).trim();
            _parseBleData(data);
          });
 
          setState(() => status = "Receiving data 📡");
          return;
        }
      }
    }
 
    setState(() => status = "Characteristic not found ❌");
  }
 
  // ─────────────────────────────────────────
  //  PARSE DATA FROM ESP32
  //
  //  Supports TWO payload formats:
  //
  //  A) Raw only (current firmware):
  //     "ax,ay,az,gx,gy,gz,temp"
  //     → falls back to magnitude-threshold check below.
  //
  //  B) Raw + classifier label (recommended — once your ESP32
  //     firmware sends the Random Forest result):
  //     "ax,ay,az,gx,gy,gz,temp,LABEL"
  //     where LABEL is e.g. NORMAL / DISTURBANCE / CRASH
  //     → trusts the edge AI decision directly, no re-thresholding.
  // ─────────────────────────────────────────
  void _parseBleData(String data) {
    final parts = data.split(',');
    if (parts.length < 7) return;
 
    final ax = double.tryParse(parts[0]) ?? accX;
    final ay = double.tryParse(parts[1]) ?? accY;
    final az = double.tryParse(parts[2]) ?? accZ;
    final gx = double.tryParse(parts[3]) ?? gyroX;
    final gy = double.tryParse(parts[4]) ?? gyroY;
    final gz = double.tryParse(parts[5]) ?? gyroZ;
    final temp = double.tryParse(parts[6]) ?? mpuTemp;
    final mag = sqrt(ax * ax + ay * ay + az * az);
 
    // Optional 8th field = classifier label from ESP32
    final label = parts.length >= 8 ? parts[7].trim().toUpperCase() : null;
 
    setState(() {
      accX = ax; accY = ay; accZ = az;
      gyroX = gx; gyroY = gy; gyroZ = gz;
      mpuTemp = temp;
      accMagnitude = mag;
      rawBleData = data;
      lastEsp32Label = label;
    });
 
    if (_isCrash(label, mag)) {
      _triggerSosIfNeeded();
    }
  }
 
  // ─────────────────────────────────────────
  //  CRASH DECISION
  //  Prefers the ESP32's own classifier output (3-class AI decision).
  //  Only falls back to a raw magnitude threshold if no label was sent.
  // ─────────────────────────────────────────
  bool _isCrash(String? label, double mag) {
    if (label != null) {
      return label == "CRASH";
    }
    // ⚠️ Fallback only — replace once your firmware sends a label.
    final speedKmh = currentSpeed * 3.6;
    return mag > 25.0 && speedKmh > 5 && mag > 20.0;
  }
 
  void _triggerSosIfNeeded() {
    final now = DateTime.now();
    if (_lastSosTrigger != null &&
        now.difference(_lastSosTrigger!).inSeconds < 30) return;
    _lastSosTrigger = now;
    _addAlert("🚨 CRASH detected! Acc=${accMagnitude.toStringAsFixed(1)} m/s²");
    sendCrashSOS();
  }
 
  // ─────────────────────────────────────────
  //  GPS TRACKING
  // ─────────────────────────────────────────
  void startLocationTracking() {
    positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 3,
      ),
    ).listen((Position pos) {
      setState(() {
        currentLat = pos.latitude;
        currentLng = pos.longitude;
        currentSpeed = pos.speed;
        trailPoints.add(LatLng(currentLat, currentLng));
        if (trailPoints.length > 800) trailPoints.removeAt(0);
      });
 
      try {
        _mapController.move(LatLng(currentLat, currentLng), 16);
      } catch (_) {}
 
      checkRestrictedArea();
      checkStationary();
    });
  }
 
  void checkRestrictedArea() {
    final dist = Geolocator.distanceBetween(
        currentLat, currentLng, safeLat, safeLng);
    final outside = dist > safeRadius;
    final newStatus =
        outside ? "⚠️ Outside Safe Zone" : "✅ Inside Safe Zone";
    if (newStatus != geoStatus) {
      setState(() => geoStatus = newStatus);
      if (outside) _addAlert("⚠️ Exited safe zone");
    }
  }
 
  void checkStationary() {
    final dist = Geolocator.distanceBetween(
        previousLat, previousLng, currentLat, currentLng);
 
    if (dist > 10) {
      previousLat = currentLat;
      previousLng = currentLng;
      lastMovementTime = DateTime.now();
      setState(() => movementStatus = "Moving 🚗");
      return;
    }
 
    if (lastMovementTime != null) {
      final halt = DateTime.now().difference(lastMovementTime!);
      if (halt.inMinutes >= 5) {
        final msg = "⚠️ Halted for ${halt.inMinutes} min";
        setState(() => movementStatus = msg);
      }
    }
  }
 
  // ─────────────────────────────────────────
  //  SOS — Native SMS only (no internet needed)
  // ─────────────────────────────────────────
  Future<void> sendCrashSOS() async {
    if (_contacts.isEmpty) {
      _addAlert("⚠️ No emergency contacts saved. SOS not sent.");
      setState(() => status = "⚠️ No contacts for SOS");
      return;
    }
 
    setState(() => status = "🚨 SOS Triggered");
 
    Position pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high);
 
    final url =
        "https://maps.google.com/?q=${pos.latitude},${pos.longitude}";
    final message =
        "🚨 CRASH DETECTED!\nSpeed: ${(currentSpeed * 3.6).toStringAsFixed(1)} km/h\n"
        "Acceleration: ${accMagnitude.toStringAsFixed(2)} m/s²\n"
        "Location: $url";
 
    final failures = await NativeSmsService.sendToAll(
      contacts: _contacts,
      body: message,
    );
 
    if (failures.isEmpty) {
      _addAlert("✅ SOS sent to ${_contacts.length} contact(s)");
      setState(() => status = "Receiving data 📡");
    } else {
      _addAlert("⚠️ SOS partial failure: ${failures.join(', ')}");
      setState(() => status = "SOS partial failure");
    }
  }
 
  // ─────────────────────────────────────────
  //  ALERT LOG
  // ─────────────────────────────────────────
  void _addAlert(String msg) {
    final now = TimeOfDay.now();
    final time =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    setState(() => alertLog.insert(0, "[$time] $msg"));
    if (alertLog.length > 50) alertLog.removeLast();
  }
 
  // ─────────────────────────────────────────
  //  HELPERS
  // ─────────────────────────────────────────
  double get speedKmh => currentSpeed * 3.6;
  Color get speedColor =>
      speedKmh > 80 ? Colors.red : (speedKmh > 50 ? Colors.orange : Colors.greenAccent);
 
  Color get accColor =>
      accMagnitude > 25 ? Colors.red : (accMagnitude > 15 ? Colors.orange : Colors.greenAccent);
 
  // ─────────────────────────────────────────
  //  BUILD
  // ─────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          "AegisLink",
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Row(
                children: [
                  Icon(
                    Icons.bluetooth,
                    size: 16,
                    color: status.contains("✅") || status.contains("📡")
                        ? Colors.greenAccent
                        : Colors.grey,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    status.contains("📡") ? "BLE OK" : status,
                    style: const TextStyle(fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.cyanAccent,
          labelColor: Colors.cyanAccent,
          unselectedLabelColor: Colors.grey,
          isScrollable: true,
          tabs: const [
            Tab(icon: Icon(Icons.dashboard, size: 18), text: "Dashboard"),
            Tab(icon: Icon(Icons.map, size: 18), text: "Map"),
            Tab(icon: Icon(Icons.warning_amber, size: 18), text: "Alerts"),
            Tab(icon: Icon(Icons.contacts, size: 18), text: "Contacts"),
          ],
        ),
      ),
 
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildDashboard(),
          _buildMap(),
          _buildAlerts(),
          ContactsScreen(
            contacts: _contacts,
            onChanged: (updated) {
              setState(() => _contacts = updated);
              _saveContacts();
            },
          ),
        ],
      ),
    );
  }
 
  // ─────────────────────────────────────────
  //  TAB 1 — DASHBOARD
  // ─────────────────────────────────────────
  Widget _buildDashboard() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionLabel("📍 GPS & Movement"),
          const SizedBox(height: 8),
          Row(children: [
            _statCard("Speed", "${speedKmh.toStringAsFixed(1)}", "km/h", speedColor,
                Icons.speed),
            const SizedBox(width: 10),
            _statCard(
                "Distance",
                _totalTrailKm(),
                "km",
                Colors.cyanAccent,
                Icons.route),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            _statCard("Lat", currentLat.toStringAsFixed(5), "°",
                Colors.white70, Icons.location_on),
            const SizedBox(width: 10),
            _statCard("Lng", currentLng.toStringAsFixed(5), "°",
                Colors.white70, Icons.location_on),
          ]),
          const SizedBox(height: 10),
          _wideCard(
            icon: geoStatus.contains("⚠") ? Icons.warning_amber : Icons.verified_user,
            label: "Zone Status",
            value: geoStatus,
            color: geoStatus.contains("⚠") ? Colors.red : Colors.greenAccent,
          ),
          const SizedBox(height: 8),
          _wideCard(
            icon: movementStatus.contains("⚠") ? Icons.pause_circle : Icons.directions_car,
            label: "Movement",
            value: movementStatus,
            color: movementStatus.contains("⚠") ? Colors.orange : Colors.cyanAccent,
          ),
 
          const SizedBox(height: 20),
 
          _sectionLabel("🔵 ESP32 MPU6050"),
          const SizedBox(height: 8),
 
          if (status != "Receiving data 📡" && !status.contains("✅"))
            _bleOffCard()
          else ...[
            Row(children: [
              _statCard("Acc Mag",
                  accMagnitude.toStringAsFixed(2), "m/s²", accColor, Icons.vibration),
              const SizedBox(width: 10),
              _statCard("Temp", mpuTemp.toStringAsFixed(1), "°C",
                  Colors.orangeAccent, Icons.thermostat),
            ]),
            const SizedBox(height: 10),
            _axisCard("Accelerometer (m/s²)", accX, accY, accZ,
                Colors.red, Colors.greenAccent, Colors.cyanAccent),
            const SizedBox(height: 10),
            _axisCard("Gyroscope (°/s)", gyroX, gyroY, gyroZ,
                Colors.red, Colors.greenAccent, Colors.cyanAccent),
            const SizedBox(height: 10),
            _crashStatusCard(),
          ],
 
          const SizedBox(height: 20),
 
          // Contact count warning
          if (_contacts.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.orange.withOpacity(0.4)),
              ),
              child: Row(children: [
                const Icon(Icons.warning_amber, color: Colors.orange, size: 18),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    "No emergency contacts saved. SOS won't be sent.",
                    style: TextStyle(color: Colors.orange, fontSize: 13),
                  ),
                ),
                TextButton(
                  onPressed: () => _tabController.animateTo(3),
                  child: const Text("Add",
                      style: TextStyle(color: Colors.cyanAccent, fontSize: 13)),
                ),
              ]),
            ),
 
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () {
                _addAlert("🆘 Manual SOS triggered");
                sendCrashSOS();
              },
              icon: const Icon(Icons.sos),
              label: const Text("Send SOS Manually",
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
 
  // ─────────────────────────────────────────
  //  TAB 2 — MAP
  // ─────────────────────────────────────────
  Widget _buildMap() {
    final center = currentLat == 0
        ? const LatLng(13.0827, 80.2707)
        : LatLng(currentLat, currentLng);
 
    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: center,
            initialZoom: 16,
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.example.ble_test_app',
            ),
 
            if (trailPoints.length > 1)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: trailPoints,
                    color: Colors.cyanAccent.withOpacity(0.8),
                    strokeWidth: 4.0,
                  ),
                ],
              ),
 
            if (currentLat != 0)
              MarkerLayer(
                markers: [
                  Marker(
                    point: LatLng(currentLat, currentLng),
                    width: 60,
                    height: 60,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(
                          width: 50,
                          height: 50,
                          decoration: BoxDecoration(
                            color: Colors.cyanAccent.withOpacity(0.2),
                            shape: BoxShape.circle,
                          ),
                        ),
                        Container(
                          width: 18,
                          height: 18,
                          decoration: BoxDecoration(
                            color: Colors.cyanAccent,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 3),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
          ],
        ),
 
        Positioned(
          bottom: 20,
          left: 16,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xDD111827),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: speedColor.withOpacity(0.6)),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(
                speedKmh.toStringAsFixed(0),
                style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w900,
                    color: speedColor),
              ),
              Text("km/h",
                  style: TextStyle(fontSize: 11, color: speedColor)),
            ]),
          ),
        ),
 
        Positioned(
          top: 12,
          left: 12,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xDD111827),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              geoStatus,
              style: TextStyle(
                  fontSize: 12,
                  color: geoStatus.contains("⚠") ? Colors.red : Colors.greenAccent),
            ),
          ),
        ),
      ],
    );
  }
 
  // ─────────────────────────────────────────
  //  TAB 3 — ALERTS
  // ─────────────────────────────────────────
  Widget _buildAlerts() {
    if (alertLog.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_circle_outline, color: Colors.greenAccent, size: 48),
            SizedBox(height: 12),
            Text("No alerts yet", style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }
 
    return ListView.builder(
      padding: const EdgeInsets.all(14),
      itemCount: alertLog.length,
      itemBuilder: (ctx, i) {
        final iscrash = alertLog[i].contains("CRASH") || alertLog[i].contains("SOS");
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: iscrash
                ? Colors.red.withOpacity(0.15)
                : Colors.orange.withOpacity(0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: iscrash ? Colors.red.withOpacity(0.4) : Colors.orange.withOpacity(0.3),
            ),
          ),
          child: Row(children: [
            Icon(
              iscrash ? Icons.car_crash : Icons.warning_amber,
              color: iscrash ? Colors.red : Colors.orange,
              size: 18,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                alertLog[i],
                style: const TextStyle(fontSize: 13, color: Colors.white70),
              ),
            ),
          ]),
        );
      },
    );
  }
 
  // ─────────────────────────────────────────
  //  CARD WIDGETS
  // ─────────────────────────────────────────
  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Text(text,
            style: const TextStyle(
                fontSize: 11,
                color: Colors.grey,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.8)),
      );
 
  Widget _statCard(
      String label, String value, String unit, Color color, IconData icon) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF111827),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF1E293B)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, color: color, size: 16),
            const SizedBox(width: 6),
            Text(label,
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ]),
          const SizedBox(height: 6),
          RichText(
            text: TextSpan(
              children: [
                TextSpan(
                    text: value,
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: color)),
                TextSpan(
                    text: " $unit",
                    style:
                        const TextStyle(fontSize: 11, color: Colors.grey)),
              ],
            ),
          ),
        ]),
      ),
    );
  }
 
  Widget _wideCard(
      {required IconData icon,
      required String label,
      required String value,
      required Color color}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 10),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label,
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
          Text(value,
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: color)),
        ]),
      ]),
    );
  }
 
  Widget _axisCard(String title, double x, double y, double z,
      Color cx, Color cy, Color cz) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title,
            style: const TextStyle(
                fontSize: 11, color: Colors.grey, fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        Row(children: [
          _axisValue("X", x, cx),
          _axisValue("Y", y, cy),
          _axisValue("Z", z, cz),
        ]),
      ]),
    );
  }
 
  Widget _axisValue(String axis, double val, Color color) {
    return Expanded(
      child: Column(children: [
        Text(axis,
            style: TextStyle(
                color: color, fontSize: 12, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(val.toStringAsFixed(2),
            style:
                const TextStyle(fontSize: 13, color: Colors.white70)),
      ]),
    );
  }
 
  Widget _crashStatusCard() {
    final crashed = lastEsp32Label != null
        ? lastEsp32Label == "CRASH"
        : accMagnitude > 25.0;
    final labelText = lastEsp32Label ?? "(no AI label received yet)";
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: crashed
            ? Colors.red.withOpacity(0.15)
            : Colors.green.withOpacity(0.1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: crashed
                ? Colors.red.withOpacity(0.5)
                : Colors.greenAccent.withOpacity(0.3),
            width: crashed ? 2 : 1),
      ),
      child: Row(children: [
        Icon(
          crashed ? Icons.car_crash : Icons.check_circle_outline,
          color: crashed ? Colors.red : Colors.greenAccent,
          size: 22,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                crashed ? "⚠️ HIGH IMPACT DETECTED" : "Normal — No crash detected",
                style: TextStyle(
                  color: crashed ? Colors.red : Colors.greenAccent,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                "AI label: $labelText",
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ),
        ),
      ]),
    );
  }
 
  Widget _bleOffCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: Column(children: [
        Icon(
          status == "Scanning..." || status == "Connecting..."
              ? Icons.bluetooth_searching
              : Icons.bluetooth_disabled,
          color: status == "Scanning..." || status == "Connecting..."
              ? Colors.cyanAccent
              : Colors.grey,
          size: 36,
        ),
        const SizedBox(height: 8),
        Text(status, style: const TextStyle(color: Colors.grey, fontSize: 13)),
        const SizedBox(height: 8),
        ElevatedButton.icon(
          onPressed: initBle,
          icon: const Icon(Icons.refresh, size: 16),
          label: const Text("Retry Scan"),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF1E293B),
            foregroundColor: Colors.cyanAccent,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ]),
    );
  }
 
  String _totalTrailKm() {
    if (trailPoints.length < 2) return "0.00";
    double total = 0;
    for (int i = 1; i < trailPoints.length; i++) {
      total += Geolocator.distanceBetween(
        trailPoints[i - 1].latitude, trailPoints[i - 1].longitude,
        trailPoints[i].latitude, trailPoints[i].longitude,
      );
    }
    return (total / 1000).toStringAsFixed(2);
  }
}
 
// ─────────────────────────────────────────────
//  CONTACTS SCREEN  (Tab 4)
// ─────────────────────────────────────────────
class ContactsScreen extends StatelessWidget {
  final List<EmergencyContact> contacts;
  final void Function(List<EmergencyContact>) onChanged;
 
  const ContactsScreen({
    super.key,
    required this.contacts,
    required this.onChanged,
  });
 
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      body: contacts.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.person_add_alt_1,
                      size: 48, color: Colors.grey),
                  const SizedBox(height: 12),
                  const Text("No contacts saved",
                      style: TextStyle(color: Colors.grey, fontSize: 14)),
                  const SizedBox(height: 4),
                  const Text("SOS needs at least one contact",
                      style: TextStyle(color: Colors.grey, fontSize: 12)),
                  const SizedBox(height: 20),
                  ElevatedButton.icon(
                    onPressed: () => _openContactForm(context, null),
                    icon: const Icon(Icons.add),
                    label: const Text("Add Contact"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.cyanAccent,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 90),
              itemCount: contacts.length,
              itemBuilder: (ctx, i) {
                final c = contacts[i];
                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF111827),
                    borderRadius: BorderRadius.circular(14),
                    border:
                        Border.all(color: const Color(0xFF1E293B)),
                  ),
                  child: Row(children: [
                    CircleAvatar(
                      backgroundColor:
                          Colors.cyanAccent.withOpacity(0.15),
                      child: Text(
                        c.name.isNotEmpty
                            ? c.name[0].toUpperCase()
                            : '?',
                        style: const TextStyle(
                            color: Colors.cyanAccent,
                            fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            Text(c.name,
                                style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white)),
                            if (c.relationship.isNotEmpty)
                              Text(c.relationship,
                                  style: const TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey)),
                            Text(c.phone,
                                style: const TextStyle(
                                    fontSize: 13,
                                    color: Colors.white70)),
                          ]),
                    ),
                    IconButton(
                      icon: const Icon(Icons.edit,
                          color: Colors.cyanAccent, size: 20),
                      onPressed: () =>
                          _openContactForm(context, c),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline,
                          color: Colors.red, size: 20),
                      onPressed: () =>
                          _confirmDelete(context, c),
                    ),
                  ]),
                );
              },
            ),
      floatingActionButton: contacts.isNotEmpty
          ? FloatingActionButton(
              onPressed: () => _openContactForm(context, null),
              backgroundColor: Colors.cyanAccent,
              foregroundColor: Colors.black,
              child: const Icon(Icons.add),
            )
          : null,
    );
  }
 
  void _openContactForm(BuildContext context, EmergencyContact? existing) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF111827),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _ContactForm(
        existing: existing,
        onSave: (contact) {
          final updated = List<EmergencyContact>.from(contacts);
          if (existing != null) {
            final idx = updated.indexWhere((c) => c.id == existing.id);
            if (idx != -1) updated[idx] = contact;
          } else {
            updated.add(contact);
          }
          onChanged(updated);
        },
      ),
    );
  }
 
  void _confirmDelete(BuildContext context, EmergencyContact c) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF111827),
        title: const Text("Delete Contact",
            style: TextStyle(color: Colors.white)),
        content: Text("Remove ${c.name} from emergency contacts?",
            style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child:
                const Text("Cancel", style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              final updated =
                  contacts.where((x) => x.id != c.id).toList();
              onChanged(updated);
            },
            child: const Text("Delete",
                style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}
 
// ─────────────────────────────────────────────
//  CONTACT FORM (bottom sheet)
// ─────────────────────────────────────────────
class _ContactForm extends StatefulWidget {
  final EmergencyContact? existing;
  final void Function(EmergencyContact) onSave;
 
  const _ContactForm({required this.existing, required this.onSave});
 
  @override
  State<_ContactForm> createState() => _ContactFormState();
}
 
class _ContactFormState extends State<_ContactForm> {
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _relationship;
 
  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.existing?.name ?? '');
    _phone = TextEditingController(text: widget.existing?.phone ?? '');
    _relationship =
        TextEditingController(text: widget.existing?.relationship ?? '');
  }
 
  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _relationship.dispose();
    super.dispose();
  }
 
  void _submit() {
    final name = _name.text.trim();
    final phone = _phone.text.trim();
    if (name.isEmpty || phone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Name and phone are required")),
      );
      return;
    }
    final contact = EmergencyContact(
      id: widget.existing?.id ??
          DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      phone: phone,
      relationship: _relationship.text.trim(),
    );
    widget.onSave(contact);
    Navigator.pop(context);
  }
 
  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, bottom + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.existing == null ? "Add Contact" : "Edit Contact",
            style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Colors.white),
          ),
          const SizedBox(height: 18),
          _field(_name, "Name", Icons.person),
          const SizedBox(height: 12),
          _field(_phone, "Phone Number", Icons.phone,
              type: TextInputType.phone),
          const SizedBox(height: 12),
          _field(_relationship, "Relationship (optional)", Icons.people),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.cyanAccent,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: Text(
                widget.existing == null ? "Save Contact" : "Update Contact",
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }
 
  Widget _field(TextEditingController ctrl, String hint, IconData icon,
      {TextInputType type = TextInputType.text}) {
    return TextField(
      controller: ctrl,
      keyboardType: type,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.grey),
        prefixIcon: Icon(icon, color: Colors.grey, size: 18),
        filled: true,
        fillColor: const Color(0xFF0A0E1A),
        contentPadding:
            const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFF1E293B)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFF1E293B)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Colors.cyanAccent),
        ),
      ),
    );
  }
}
 