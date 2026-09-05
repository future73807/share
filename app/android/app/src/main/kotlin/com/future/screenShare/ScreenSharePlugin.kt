package com.future.screenShare

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * 屏幕共享原生插件(唯一处理 screen_share_channel,修复与 MainActivity 重复注册导致
 * 授权弹窗不显示的问题)。
 *
 * 职责:
 *  1. mediaProjection 前台服务生命周期(Android 14+ 要求 startForeground 之后才能
 *     getMediaProjection,否则确认授权后直接闪退 SecurityException);
 *  2. 系统内部声音采集(AudioPlaybackCapture),经 flutter_webrtc 的
 *     capturePostProcessing 注入 WebRTC 音频轨道,与麦克风按模式混音;
 *  3. 回声抑制:麦克风走 VOICE_COMMUNICATION 源(硬件 AEC),屏幕内音为纯数字采集,
 *     混音在采集后处理阶段完成,不引入扬声器二次采集。
 */
class ScreenSharePlugin : FlutterPlugin, MethodCallHandler, ActivityAware {

    private lateinit var channel: MethodChannel
    private var activity: Activity? = null
    private var appContext: Context? = null
    private var projectionManager: MediaProjectionManager? = null

    // 音频模式(none/mic/screen/mixed),由 Dart 侧设置
    private val mixProcessor = ScreenAudioMixProcessor()

    // 系统音频采集状态
    private var audioRecord: AudioRecord? = null
    private var captureExecutor = Executors.newSingleThreadExecutor()
    @Volatile private var capturing = false
    private var ownProjection: MediaProjection? = null // 回退方案:插件自建的投影
    private var projectionCallback: MediaProjection.Callback? = null

    // 回退方案的用户授权回调
    private var pendingConsentResult: Result? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
        appContext = binding.applicationContext
        projectionManager =
            appContext?.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as? MediaProjectionManager
        registerAudioProcessor()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        // 关键:从 flutter_webrtc 的处理链摘除混音器,否则引擎重建后
        // 会重复注册多个实例,环形缓冲被成倍消耗导致屏幕内音丢失
        try {
            FlutterWebRTCPlugin.sharedSingleton?.audioProcessingController
                ?.capturePostProcessing?.removeProcessor(mixProcessor)
        } catch (_: Throwable) {}
        mixProcessor.registered = false
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener { requestCode, resultCode, data ->
            onActivityResult(requestCode, resultCode, data)
        }
    }

    override fun onDetachedFromActivityForConfigChanges() { activity = null }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener { requestCode, resultCode, data ->
            onActivityResult(requestCode, resultCode, data)
        }
    }

    override fun onDetachedFromActivity() { activity = null }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "startCaptureService" -> {
                val ctx = appContext
                if (ctx == null) {
                    result.error("NO_CONTEXT", "application context is null", null)
                    return
                }
                val intent = Intent(ctx, ScreenCaptureService::class.java)
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        ctx.startForegroundService(intent)
                    } else {
                        ctx.startService(intent)
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "startForegroundService failed", e)
                    mainHandler.post { result.success(false) }
                    return
                }
                // 等待服务完成 startForeground(Android 14+ 硬性要求)
                Thread {
                    val ok = ScreenCaptureService.awaitForeground(3, TimeUnit.SECONDS)
                    mainHandler.post { result.success(ok) }
                }.start()
            }
            "stopCaptureService" -> {
                val ctx = appContext
                if (ctx != null) ctx.stopService(Intent(ctx, ScreenCaptureService::class.java))
                result.success(null)
            }
            "setAudioShareMode" -> {
                mixProcessor.mode = when (call.argument<String>("mode")) {
                    "none" -> ScreenAudioMixProcessor.MODE_NONE
                    "screen" -> ScreenAudioMixProcessor.MODE_SCREEN
                    "mixed" -> ScreenAudioMixProcessor.MODE_MIXED
                    else -> ScreenAudioMixProcessor.MODE_MIC
                }
                result.success(null)
            }
            "isSystemAudioCaptureSupported" -> {
                result.success(
                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && projectionManager != null
                )
            }
            "startSystemAudioCapture" -> {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                    result.error("UNSUPPORTED", "AudioPlaybackCapture 需要 Android 10+", null)
                    return
                }
                val trackId = call.argument<String>("trackId") ?: ""
                val projection = findFlutterWebrtcProjection(trackId)
                if (projection != null) {
                    startAudioCapture(projection, ownedByPlugin = false)
                    result.success(true)
                } else {
                    // 无法复用 flutter_webrtc 的投影时,走插件自建授权(第二次弹窗)
                    result.error("NEED_PROJECTION", "需要单独的屏幕投影授权", null)
                }
            }
            "startAudioProjectionFallback" -> {
                val act = activity
                val pm = projectionManager
                if (act == null || pm == null) {
                    result.success(false)
                    return
                }
                pendingConsentResult = result
                act.startActivityForResult(pm.createScreenCaptureIntent(), REQUEST_AUDIO_CONSENT)
            }
            "stopSystemAudioCapture" -> {
                stopAudioCaptureInternal(releaseOwnProjection = false)
                result.success(null)
            }
            "stopAllCapture" -> {
                stopAudioCaptureInternal(releaseOwnProjection = true)
                result.success(null)
            }
            "getAudioMixLevel" -> {
                // 供 UI 电平条轮询:outPeak=送入编码的音频峰值,captureWrites=屏幕内音采集累计样本
                result.success(mapOf(
                    "outPeak" to mixProcessor.lastOutPeak,
                    "captureWrites" to mixProcessor.captureWrites,
                    "mode" to mixProcessor.mode
                ))
            }
            else -> result.notImplemented()
        }
    }

    /**
     * 通过反射复用 flutter_webrtc 已创建的 MediaProjection(避免二次授权弹窗)。
     * 链路: sharedSingleton -> methodCallHandler -> getUserMediaImpl
     *      -> getCapturerInfo(trackId).capturer -> mediaProjection 字段。
     */
    private fun findFlutterWebrtcProjection(trackId: String): MediaProjection? {
        if (trackId.isEmpty()) {
            Log.w(TAG, "复用投影失败: trackId 为空")
            return null
        }
        return try {
            val singleton = FlutterWebRTCPlugin.sharedSingleton
            if (singleton == null) {
                Log.w(TAG, "复用投影失败: flutter_webrtc 插件未初始化")
                return null
            }
            val mch = singleton.javaClass.getDeclaredField("methodCallHandler")
                .apply { isAccessible = true }.get(singleton)
            if (mch == null) {
                Log.w(TAG, "复用投影失败: methodCallHandler 为空")
                return null
            }
            val gum = mch.javaClass.getDeclaredField("getUserMediaImpl")
                .apply { isAccessible = true }.get(mch)
            if (gum == null) {
                Log.w(TAG, "复用投影失败: getUserMediaImpl 为空")
                return null
            }
            val info = gum.javaClass
                .getMethod("getCapturerInfo", String::class.java)
                .invoke(gum, trackId)
            if (info == null) {
                Log.w(TAG, "复用投影失败: 找不到轨道 $trackId 的采集信息")
                return null
            }
            val capturer = info.javaClass.getField("capturer").get(info)
            if (capturer == null) {
                Log.w(TAG, "复用投影失败: capturer 为空")
                return null
            }
            var c: Class<*>? = capturer.javaClass
            while (c != null) {
                val f = try {
                    c!!.getDeclaredField("mediaProjection")
                } catch (e: NoSuchFieldException) {
                    null
                }
                if (f != null) {
                    f.isAccessible = true
                    val mp = f.get(capturer) as? MediaProjection
                    if (mp == null) Log.w(TAG, "复用投影失败: mediaProjection 字段为空")
                    return mp
                }
                c = c.superclass
            }
            Log.w(TAG, "复用投影失败: ${capturer.javaClass.name} 无 mediaProjection 字段")
            null
        } catch (t: Throwable) {
            Log.w(TAG, "复用 flutter_webrtc MediaProjection 失败: ${t.message}")
            null
        }
    }

    @SuppressLint("MissingPermission")
    private fun startAudioCapture(projection: MediaProjection, ownedByPlugin: Boolean) {
        if (capturing) return
        val ctx = appContext ?: return

        val playbackConfig = AudioPlaybackCaptureConfiguration.Builder(projection)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
            .build()

        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(ScreenAudioMixProcessor.SRC_SAMPLE_RATE)
            .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
            .build()

        val minBuf = AudioRecord.getMinBufferSize(
            ScreenAudioMixProcessor.SRC_SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        ).coerceAtLeast(2048)

        val record = AudioRecord.Builder()
            .setAudioFormat(format)
            .setBufferSizeInBytes(minBuf * 4)
            .setAudioPlaybackCaptureConfig(playbackConfig)
            .build()

        // 投影被系统/用户停止时同步停止音频采集
        if (ownedByPlugin) {
            val cb = object : MediaProjection.Callback() {
                override fun onStop() {
                    mainHandler.post {
                        stopAudioCaptureInternal(releaseOwnProjection = true)
                        channel.invokeMethod("onSystemAudioCaptureStopped", null)
                    }
                }
            }
            projectionCallback = cb
            projection.registerCallback(cb, mainHandler)
        }

        audioRecord = record
        capturing = true
        record.startRecording()
        captureExecutor.execute {
            val buf = ShortArray(2048)
            while (capturing) {
                val n = try {
                    record.read(buf, 0, buf.size)
                } catch (t: Throwable) {
                    break
                }
                if (n > 0) {
                    mixProcessor.writeCaptureSamples(buf, n)
                } else if (n < 0) {
                    break
                }
            }
            try { record.stop() } catch (_: Throwable) {}
            try { record.release() } catch (_: Throwable) {}
        }
        Log.i(TAG, "系统音频采集已启动 (ownedByPlugin=$ownedByPlugin)")
    }

    private fun stopAudioCaptureInternal(releaseOwnProjection: Boolean) {
        capturing = false
        audioRecord = null
        projectionCallback?.let { cb ->
            ownProjection?.unregisterCallback(cb)
        }
        projectionCallback = null
        if (releaseOwnProjection) {
            try { ownProjection?.stop() } catch (_: Throwable) {}
            ownProjection = null
        }
        mixProcessor.ring.clear()
    }

    private fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_AUDIO_CONSENT) return false
        val pending = pendingConsentResult
        pendingConsentResult = null
        if (pending == null) return true

        if (resultCode == Activity.RESULT_OK && data != null && projectionManager != null) {
            Thread {
                var ok = false
                try {
                    // 确保前台服务已就绪(Android 14+ getMediaProjection 前置条件)
                    ScreenCaptureService.awaitForeground(3, TimeUnit.SECONDS)
                    val projection =
                        projectionManager!!.getMediaProjection(resultCode, data)
                    ownProjection = projection
                    startAudioCapture(projection, ownedByPlugin = true)
                    ok = true
                } catch (t: Throwable) {
                    Log.e(TAG, "getMediaProjection(音频回退)失败", t)
                }
                val finalOk = ok
                mainHandler.post { pending.success(finalOk) }
            }.start()
        } else {
            mainHandler.post { pending.success(false) }
        }
        return true
    }

    private fun registerAudioProcessor() {
        // flutter_webrtc 的插件可能晚于本插件注册,轮询直至拿到 sharedSingleton
        fun tryRegister(attempt: Int) {
            if (mixProcessor.registered) return
            val plugin = FlutterWebRTCPlugin.sharedSingleton
            if (plugin != null) {
                try {
                    plugin.audioProcessingController.capturePostProcessing
                        .addProcessor(mixProcessor)
                    mixProcessor.registered = true
                    Log.i(TAG, "音频混音处理器已注册到 capturePostProcessing")
                    return
                } catch (t: Throwable) {
                    Log.w(TAG, "注册音频处理器失败: ${t.message}")
                }
            }
            if (attempt < 20) {
                mainHandler.postDelayed({ tryRegister(attempt + 1) }, 250)
            }
        }
        tryRegister(0)
    }

    companion object {
        private const val TAG = "ScreenSharePlugin"
        const val CHANNEL_NAME = "screen_share_channel"
        private const val REQUEST_AUDIO_CONSENT = 2002
    }
}
