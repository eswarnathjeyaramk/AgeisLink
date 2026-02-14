import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';


bool isReconnecting = false;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: BleHome(),
    );
  }
}

class BleHome extends StatefulWidget {
  const BleHome({super.key});

  @override
  State<BleHome> createState() => _BleHomeState();
}

class _BleHomeState extends State<BleHome> {
  // 🔹 VARIABLES
  String status = "Waiting...";
  BluetoothDevice? espDevice;
  BluetoothCharacteristic? notifyChar;
  String countValue = "--";
  


  @override
  void initState() {
    super.initState();
    initBle();
  }

  // 🔹 SCAN + FIND ESP32
  Future<void> initBle() async {
    await Permission.locationWhenInUse.request();
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();

    if (await FlutterBluePlus.isOn == false) {
      setState(() {
        status = "Bluetooth is OFF";
      });
      return;
    }

    setState(() {
      status = "Scanning...";
    });

    FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));

    FlutterBluePlus.scanResults.listen((results) async {
      for (ScanResult r in results) {
        if (r.device.name == "ESP32_ALERT_DEVICE") {
          await FlutterBluePlus.stopScan();
          espDevice = r.device;

          setState(() {
            status = "Connecting to ESP32...";
          });

          await connectToEsp32();
          return;
        }
      }
    });
  }

  // 🔹 CONNECT + SUBSCRIBE
  Future<void> connectToEsp32() async {
    if (espDevice == null) return;

    await espDevice!.connect(autoConnect: false);

    setState(() {
      status = "Connected ✅ Discovering services...";
    });

    espDevice!.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected && !isReconnecting) {
        isReconnecting = true;
        setState(() {
          status = "Disconnected ❌ Reconnecting...";
        });
        initBle();
      }
    });

    List<BluetoothService> services =
        await espDevice!.discoverServices();

        for (var service in services) {
  debugPrint("SERVICE UUID: ${service.uuid}");

  for (var char in service.characteristics) {
    debugPrint("  CHAR UUID: ${char.uuid}");
    debugPrint("  Notify: ${char.properties.notify}");
    debugPrint("  Write: ${char.properties.write}");
  }
}


    for (var service in services) {
      for (var char in service.characteristics) {
        if (char.properties.notify) {
          notifyChar = char;

          await notifyChar!.setNotifyValue(true);

          notifyChar!.value.listen((value) async {
  String data = String.fromCharCodes(value);

  setState(() {
    countValue = data;
    status = "Receiving data 📡";
  });

 if (data.contains("CRASH")) {
  await sendCrashSOS();

}

});

          return;
        }
      }
    }

    setState(() {
      status = "Notify characteristic not found ❌";
    });
  }
    // 🚨 SEND SOS MESSAGE WITH LOCATION
Future<void> sendCrashSOS() async {
  await Permission.location.request();

  Position position = await Geolocator.getCurrentPosition(
    desiredAccuracy: LocationAccuracy.high,
  );

  String locationUrl =
      "https://maps.google.com/?q=${position.latitude},${position.longitude}";

  String message =
      "CRASH DETECTED! Immediate assistance required.\nLocation:\n$locationUrl";

  List<String> contacts = [
    "9514823002",
    "8939243866",
  ];

  for (String number in contacts) {
    final Uri smsUri = Uri.parse(
        "sms:$number?body=${Uri.encodeComponent(message)}");

    if (await canLaunchUrl(smsUri)) {
      await launchUrl(smsUri);
    }
  }

  setState(() {
    status = "🚨 SOS Triggered (SMS App Opened)";
  });
}


  // 🔹 UI
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("BLE Test")),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(status, style: const TextStyle(fontSize: 20)),
            const SizedBox(height: 20),
            Text(
              "Count: $countValue",
              style: const TextStyle(fontSize: 32),
            ),
          ],
        ),
      ),
    );
  }
}