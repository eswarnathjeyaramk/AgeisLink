import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:async';
import 'dart:math';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

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
      title: 'Geo Movement Analysis',
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

  // ── Tabs ─────────────────────────────────
  late TabController _tabController;

  // ── Map controller ───────────────────────
  final MapController _mapController = MapController();

  // ── Crash cooldown ───────────────────────
  DateTime? _lastSosTrigger;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
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
  //  BLE – SCAN
  // ─────────────────────────────────────────
  Future<void> initBle() async {
    await Permission.locationWhenInUse.request();
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();

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

    // Auto-reconnect on drop
    espDevice!.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected && !isReconnecting) {
        isReconnecting = true;
        setState(() => status = "Reconnecting...");
        Future.delayed(const Duration(seconds: 3), () => initBle());
      }
    });

    // Discover services
    List<BluetoothService> services = await espDevice!.discoverServices();

    for (var service in services) {
      for (var char in service.characteristics) {
        if (char.properties.notify) {
          notifyChar = char;
          await notifyChar!.setNotifyValue(true);

          // ── Single listener — no duplicate ──
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
  //  PARSE CSV FROM ESP32
  //  Format: "ax,ay,az,gx,gy,gz,temp"
  //  e.g.  "0.12,-0.05,9.81,1.2,-0.3,0.1,28.5"
  // ─────────────────────────────────────────
  void _parseBleData(String data) {
    final parts = data.split(',');
    if (parts.length >= 7) {
      final ax = double.tryParse(parts[0]) ?? accX;
      final ay = double.tryParse(parts[1]) ?? accY;
      final az = double.tryParse(parts[2]) ?? accZ;
      final gx = double.tryParse(parts[3]) ?? gyroX;
      final gy = double.tryParse(parts[4]) ?? gyroY;
      final gz = double.tryParse(parts[5]) ?? gyroZ;
      final temp = double.tryParse(parts[6]) ?? mpuTemp;
      final mag = sqrt(ax * ax + ay * ay + az * az);

      setState(() {
        accX = ax; accY = ay; accZ = az;
        gyroX = gx; gyroY = gy; gyroZ = gz;
        mpuTemp = temp;
        accMagnitude = mag;
        rawBleData = data;
      });

      // Crash detection: >2.5g spike
      if (mag > 25.0 && verifyCrash()) {
        _triggerSosIfNeeded();
      }
    }
  }

  // ─────────────────────────────────────────
  //  CRASH VERIFY (speed + acc both required)
  // ─────────────────────────────────────────
  bool verifyCrash() {
    final speedKmh = currentSpeed * 3.6;
    return speedKmh > 5 && accMagnitude > 20.0;
  }

  // Prevent SOS spam — 30 s cooldown
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

      // Move map camera to follow user
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
  //  SOS
  // ─────────────────────────────────────────
  Future<void> sendCrashSOS() async {
    setState(() => status = "🚨 SOS Triggered");

    Position pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high);

    final url =
        "https://maps.google.com/?q=${pos.latitude},${pos.longitude}";
    final message =
        "🚨 CRASH DETECTED!\nSpeed: ${(currentSpeed * 3.6).toStringAsFixed(1)} km/h\n"
        "Acceleration: ${accMagnitude.toStringAsFixed(2)} m/s²\n"
        "Location: $url";

    // ⚠️ Replace with your emergency contacts
    final contacts = ["9514823002", "8939243866"];

    for (final number in contacts) {
      final smsUri = Uri.parse(
          "sms:$number?body=${Uri.encodeComponent(message)}");
      if (await canLaunchUrl(smsUri)) await launchUrl(smsUri);
    }
  }

  // ─────────────────────────────────────────
  //  ALERT LOG
  // ─────────────────────────────────────────
  void _addAlert(String msg) {
    final time = TimeOfDay.now().format(context);
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
          "Geo Movement Analysis",
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
        ),
        actions: [
          // BLE status dot
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
          tabs: const [
            Tab(icon: Icon(Icons.dashboard, size: 18), text: "Dashboard"),
            Tab(icon: Icon(Icons.map, size: 18), text: "Map"),
            Tab(icon: Icon(Icons.warning_amber, size: 18), text: "Alerts"),
          ],
        ),
      ),

      body: TabBarView(
        controller: _tabController,
        children: [
          _buildDashboard(),
          _buildMap(),
          _buildAlerts(),
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
          // ── GPS Section ──
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

          // ── MPU6050 Section ──
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

          // ── Manual SOS Button ──
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
              userAgentPackageName: 'com.example.blegeo',
            ),

            // Movement trail
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

            // Current position marker
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

        // Speed HUD bottom-left
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

        // Zone status top-left
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
    final crashed = accMagnitude > 25.0;
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
        Text(
          crashed ? "⚠️ HIGH IMPACT DETECTED" : "Normal — No crash detected",
          style: TextStyle(
            color: crashed ? Colors.red : Colors.greenAccent,
            fontSize: 13,
            fontWeight: FontWeight.w700,
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

  // Trail distance helper
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