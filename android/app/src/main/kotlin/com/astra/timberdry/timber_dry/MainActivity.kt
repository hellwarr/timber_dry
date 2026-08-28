package com.astra.timberdry.timber_dry

import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.astra.timberdry/hardware_id"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "getHardwareId") {
                val androidId = Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID)
                val cleanId = (androidId ?: "UNKNOWN").uppercase()
                val formatted = if (cleanId.length >= 12) {
                    "APP-${cleanId.substring(0, 4)}-${cleanId.substring(4, 8)}-${cleanId.substring(8, 12)}"
                } else {
                    "APP-$cleanId"
                }
                result.success(formatted)
            } else {
                result.notImplemented()
            }
        }
    }
}
