package com.example.hello_flutter

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var bridge: EnCryNoteBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bridge = EnCryNoteBridge.register(flutterEngine.dartExecutor.binaryMessenger, this)
    }

    // The shield must already cover the window when the system takes its
    // app-switcher snapshot, so it is installed from the lifecycle callback
    // rather than from a Dart round trip.
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        bridge?.onWindowFocusChanged(hasFocus)
    }

    override fun onPause() {
        bridge?.onPause()
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
        bridge?.onResume()
    }

    // The document picker and save panel are system activities; their result
    // reaches the bridge here and nowhere else.
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (bridge?.onActivityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }
}
