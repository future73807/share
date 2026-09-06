package com.example.screen_share_app

import android.content.Intent
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.view.View
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import com.future.screenShare.ScreenSharePlugin

class MainActivity : FlutterActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 去掉顶部安全区:内容延伸到透明状态栏/导航栏底下
        // (黑色状态栏图标由 ScreenSharePlugin 的 enterImmersive/
        //  exitImmersive 与 Dart 侧 _applyDarkStatusBarIcons 统一设置)。
        if (Build.VERSION.SDK_INT >= 30) {
            window.setDecorFitsSystemWindows(false)
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = (
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                    or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                    or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION)
        }
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT
    }

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
