package com.example.screen_share_app

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.content.pm.PackageManager
import android.Manifest
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import com.future.screenShare.WakeLockService
import android.app.Activity
import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.graphics.BitmapFactory
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts

import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "screen_share_channel"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestForegroundServicePermission" -> {
                    // 这里可以直接返回true或处理权限逻辑
                    result.success(true)
                }
                "requestCaptureVideoOutputPermission" -> {
                    result.success(true)
                }
                "requestProjectMediaPermission" -> {
                    result.success(true)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }
    
    private val REQUIRED_PERMISSIONS = arrayOf(
        android.Manifest.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE,
        android.Manifest.permission.BLUETOOTH_CONNECT,
        android.Manifest.permission.BLUETOOTH_ADVERTISE,
        android.Manifest.permission.BLUETOOTH_SCAN,
        android.Manifest.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION,
        android.Manifest.permission.FOREGROUND_SERVICE_LOCATION,
        android.Manifest.permission.ACCESS_COARSE_LOCATION,
        android.Manifest.permission.ACCESS_FINE_LOCATION,
        android.Manifest.permission.ACCESS_BACKGROUND_LOCATION
    )
    private val PERMISSION_REQUEST_CODE = 1001
    private lateinit var requestPermissionLauncher: ActivityResultLauncher<String>

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 动态权限申请逻辑建议迁移到插件或原生Activity中，移除 registerForActivityResult 相关代码
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // TODO: 使用更适合Flutter的权限处理方式
        } else {
            requestPermissions(REQUIRED_PERMISSIONS, PERMISSION_REQUEST_CODE)
        }
    }

    private fun allPermissionsGranted(): Boolean {
        return REQUIRED_PERMISSIONS.all {
            checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
        }
    }
    
    private fun startWakeLockService() {
        val serviceIntent = Intent(this, WakeLockService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent)
        } else {
            startService(serviceIntent)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == PERMISSION_REQUEST_CODE) {
            if (grantResults.all { it == PackageManager.PERMISSION_GRANTED }) {
                // 所有权限都已获得，启动前台服务
                startWakeLockService()
            }
        }
    }
    
    override fun onDestroy() {
        super.onDestroy()
        // 在Activity销毁时停止服务
        stopService(Intent(this, WakeLockService::class.java))
    }
}