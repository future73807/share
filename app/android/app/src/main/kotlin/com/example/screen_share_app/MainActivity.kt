package com.example.screen_share_app

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import com.future.screenShare.ScreenSharePlugin

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // 先由 super 注册 GeneratedPluginRegistrant(flutter_webrtc 等),
        // 再注册 ScreenSharePlugin,保证 FlutterWebRTCPlugin.sharedSingleton 可用,
        // 且 screen_share_channel 只有唯一处理器(修复授权弹窗不显示)。
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(ScreenSharePlugin())
    }

    override fun onDestroy() {
        stopService(Intent(this, com.future.screenShare.WakeLockService::class.java))
        super.onDestroy()
    }
}
