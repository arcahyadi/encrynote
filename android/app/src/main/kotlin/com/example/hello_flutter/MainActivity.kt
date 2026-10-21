package com.example.hello_flutter

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        EnCryNoteBridge.register(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
    }
}
