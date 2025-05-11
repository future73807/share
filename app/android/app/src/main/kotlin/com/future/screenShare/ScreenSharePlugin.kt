package com.future.screenShare

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.view.Surface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

import io.flutter.plugin.common.PluginRegistry.ActivityResultListener

class ScreenSharePlugin: FlutterPlugin, MethodCallHandler, ActivityAware, ActivityResultListener {
    private lateinit var channel : MethodChannel
    private lateinit var context: Context
    private var activity: Activity? = null
    private var mediaProjectionManager: MediaProjectionManager? = null
    private var mediaProjection: MediaProjection? = null
    private var surface: Surface? = null

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "screen_share_channel")
        channel.setMethodCallHandler(this)
        context = flutterPluginBinding.applicationContext
        mediaProjectionManager = context.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "requestScreenCapture" -> {
                activity?.let { activity ->
                    val intent = mediaProjectionManager?.createScreenCaptureIntent()
                    activity.startActivityForResult(intent, SCREEN_CAPTURE_REQUEST_CODE)
                    result.success(null)
                } ?: result.error("ACTIVITY_NULL", "Activity is null", null)
            }
            "stopScreenCapture" -> {
                stopScreenCapture()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun stopScreenCapture() {
        mediaProjection?.stop()
        mediaProjection = null
        surface?.release()
        surface = null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
        stopScreenCapture()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == SCREEN_CAPTURE_REQUEST_CODE) {
            if (resultCode == Activity.RESULT_OK && data != null) {
                mediaProjection = mediaProjectionManager?.getMediaProjection(resultCode, data)
                channel.invokeMethod("onScreenCapturePermissionGranted", null)
            } else {
                channel.invokeMethod("onScreenCapturePermissionDenied", null)
            }
            return true
        }
        return false
    }

    companion object {
        private const val SCREEN_CAPTURE_REQUEST_CODE = 1000
    }
}