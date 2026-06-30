import 'package:flutter/services.dart';
 
/// Sends SMS silently via the native Android SmsManager.
/// No internet required — only a cellular signal (2G/3G/4G).
/// No app opens, no user tap needed, once SEND_SMS permission is granted.
class NativeSmsService {
  static const _channel = MethodChannel('aegislink/sms');
 
  /// Returns null on success, error string on failure.
  static Future<String?> sendSms({
    required String to,
    required String message,
  }) async {
    try {
      await _channel.invokeMethod('sendSms', {
        'phone': to,
        'message': message,
      });
      return null;
    } on PlatformException catch (e) {
      return e.message ?? 'Unknown native SMS error';
    } on MissingPluginException {
      return 'Native SMS channel not registered (check MainActivity.kt)';
    } catch (e) {
      return e.toString();
    }
  }
 
  /// Send to all contacts. Returns list of failures (empty = all succeeded).
  static Future<List<String>> sendToAll({
    required List<dynamic> contacts, // List<EmergencyContact>
    required String body,
  }) async {
    final failures = <String>[];
    for (final c in contacts) {
      final err = await sendSms(to: c.phone, message: body);
      if (err != null) failures.add('${c.name}: $err');
    }
    return failures;
  }
}