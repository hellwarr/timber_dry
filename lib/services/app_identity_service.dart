import 'package:flutter/services.dart';

class AppIdentityService {
  static const MethodChannel _channel = MethodChannel('com.astra.timberdry/hardware_id');
  static String? _cachedId;

  static Future<String> getAppInstanceId() async {
    if (_cachedId != null) return _cachedId!;

    try {
      final String? hwId = await _channel.invokeMethod<String>('getHardwareId');
      if (hwId != null && hwId.isNotEmpty && hwId != 'APP-UNKNOWN') {
        _cachedId = hwId;
        return _cachedId!;
      }
    } catch (_) {}

    _cachedId = 'APP-HARDWARE-ID';
    return _cachedId!;
  }
}
