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
import android.os.IBinder
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
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * 屏幕共享原生插件(screen_share_channel 唯一处理器)。
 *
 * 职责:
 *  1. mediaProjection 前台服务生命周期(Android 14+ 必须先 startForeground);
 *  2. 声音内录(Android 10+ AudioPlaybackCapture):复用 flutter_webrtc 已授权的
 *     投影实例采集系统内音,数据经 ScreenAudioMixProcessor 注入 WebRTC 上行;
 *  3. 声音模式控制(透传/替换/叠加/置零)。
 */
class ScreenSharePlugin : FlutterPlugin, MethodCallHandler, ActivityAware {

    private lateinit var channel: MethodChannel
    private var activity: Activity? = null
    private var appContext: Context? = null
    private var projectionManager: MediaProjectionManager? = null
    private val mixProcessor = ScreenAudioMixProcessor()
    private val mainHandler = Handler(Looper.getMainLooper())

    init {
        audioBridge = mixProcessor
    }

    // 声音内录采集状态
    private var audioRecord: AudioRecord? = null
    private var captureExecutor: ExecutorService? = null
    @Volatile private var audioCapturing = false
    private var ownProjection: MediaProjection? = null
    private var projectionCallback: MediaProjection.Callback? = null
    private var pendingFallbackResult: Result? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
        appContext = binding.applicationContext
        projectionManager = appContext?.getSystemService(Context.MEDIA_PROJECTION_SERVICE)
            as? MediaProjectionManager
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
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "startCaptureService" -> {
                val ctx = appContext
                if (ctx == null) {
                    result.error("NO_CONTEXT", null, null)
                    return
                }
                try {
                    val intent = Intent(ctx, ScreenCaptureService::class.java)
                        .setAction(ScreenCaptureService.ACTION_START)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        ctx.startForegroundService(intent)
                    } else {
                        ctx.startService(intent)
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "startForegroundService 失败", e)
                    mainHandler.post { result.success(false) }
                    return
                }
                Thread {
                    val ok = ScreenCaptureService.awaitForeground(3, TimeUnit.SECONDS)
                    mainHandler.post { result.success(ok) }
                }.start()
            }
            "stopCaptureService" -> {
                val ctx = appContext
                if (ctx != null) {
                    ctx.startService(
                        Intent(ctx, ScreenCaptureService::class.java)
                            .setAction(ScreenCaptureService.ACTION_STOP_AUDIO))
                    ctx.stopService(Intent(ctx, ScreenCaptureService::class.java))
                }
                result.success(null)
            }
            "setAudioShareMode" -> {
                mixProcessor.mode = when (call.argument<String>("mode")) {
                    "none" -> ScreenAudioMixProcessor.MODE_NONE
                    "screen" -> ScreenAudioMixProcessor.MODE_SCREEN
                    "mixed" -> ScreenAudioMixProcessor.MODE_MIXED
                    else -> ScreenAudioMixProcessor.MODE_MIC
                }
                Log.i(TAG, "声音模式 -> ${call.argument<String>("mode")}")
                result.success(null)
            }
            "startSystemAudioCapture" -> {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                    result.error("UNSUPPORTED", "声音内录需要 Android 10+", null)
                    return
                }
                val trackId = call.argument<String>("trackId") ?: ""
                val projection = findFlutterWebrtcProjection(trackId)
                if (projection != null) {
                    startAudioCapture(projection, ownedByPlugin = false)
                    result.success(true)
                } else {
                    // 无法复用 flutter_webrtc 的投影实例:由 Dart 侧触发
                    // startAudioProjectionFallback(我们自己的系统授权)
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
                pendingFallbackResult = result
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
        if (trackId.isEmpty()) return null
        return try {
            val singleton = FlutterWebRTCPlugin.sharedSingleton ?: return null
            val mch = singleton.javaClass.getDeclaredField("methodCallHandler")
                .apply { isAccessible = true }.get(singleton) ?: return null
            val gum = mch.javaClass.getDeclaredField("getUserMediaImpl")
                .apply { isAccessible = true }.get(mch) ?: return null
            val info = gum.javaClass
                .getMethod("getCapturerInfo", String::class.java)
                .invoke(gum, trackId) ?: return null
            val capturer = info.javaClass.getField("capturer").get(info) ?: return null
            var c: Class<*>? = capturer.javaClass
            while (c != null) {
                val f = try {
                    c!!.getDeclaredField("mediaProjection")
                } catch (e: NoSuchFieldException) {
                    null
                }
                if (f != null) {
                    f.isAccessible = true
                    return f.get(capturer) as? MediaProjection
                }
                c = c.superclass
            }
            null
        } catch (t: Throwable) {
            Log.w(TAG, "复用 flutter_webrtc MediaProjection 失败: ${t.message}")
            null
        }
    }

    @SuppressLint("MissingPermission")
    private fun startAudioCapture(projection: MediaProjection, ownedByPlugin: Boolean) {
        if (audioCapturing) return
        val ctx = appContext ?: return

        val playbackConfig = AudioPlaybackCaptureConfiguration.Builder(projection)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
            .addMatchingUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
            .addMatchingUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
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
        audioCapturing = true
        val st = record.startRecording()
        Log.i(TAG, "系统音频采集启动: state=${record.state} recState=${record.recordingState} " +
                "startRet=$st ownedByPlugin=$ownedByPlugin")

        captureExecutor = Executors.newSingleThreadExecutor()
        captureExecutor!!.execute {
            val buf = ShortArray(2048)
            var reads = 0L
            var samples = 0L
            var lastLog = System.currentTimeMillis()
            while (audioCapturing) {
                val n = try {
                    record.read(buf, 0, buf.size)
                } catch (t: Throwable) {
                    Log.e(TAG, "AudioRecord.read 异常", t)
                    break
                }
                reads++
                if (n > 0) {
                    samples += n
                    mixProcessor.writeCaptureSamples(buf, n)
                } else if (n < 0) {
                    Log.e(TAG, "AudioRecord.read 返回 $n,停止采集")
                    break
                }
                val now = System.currentTimeMillis()
                if (now - lastLog >= 1000) {
                    Log.i(TAG, "音频采集: reads=$reads samples=$samples " +
                            "recState=${record.recordingState} lastRead=$n")
                    lastLog = now
                }
            }
            Log.w(TAG, "系统音频采集线程退出 (audioCapturing=$audioCapturing)")
            try { record.stop() } catch (_: Throwable) {}
            try { record.release() } catch (_: Throwable) {}
        }
    }

    private fun stopAudioCaptureInternal(releaseOwnProjection: Boolean) {
        audioCapturing = false
        audioRecord = null
        if (releaseOwnProjection) {
            try { ownProjection?.stop() } catch (_: Throwable) {}
            ownProjection = null
        }
        mixProcessor.ring.clear()
        Log.i(TAG, "系统音频采集已停止 (releaseOwnProjection=$releaseOwnProjection)")
    }

    private fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_AUDIO_CONSENT) return false
        val pending = pendingFallbackResult
        pendingFallbackResult = null
        if (pending == null) return true

        if (resultCode == Activity.RESULT_OK && data != null && projectionManager != null) {
            Thread {
                var ok = false
                try {
                    // 确保前台服务已就绪(Android 14+ getMediaProjection 前置条件)
                    ScreenCaptureService.awaitForeground(3, TimeUnit.SECONDS)
                    val projection = projectionManager!!.getMediaProjection(resultCode, data)
                    ownProjection = projection
                    startAudioCapture(projection, ownedByPlugin = true)
                    ok = true
                } catch (t: Throwable) {
                    Log.e(TAG, "音频回退投影创建失败", t)
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

        /** 静态桥:前台服务采集线程经此把系统内音写入混音器 */
        @JvmStatic
        @Volatile
        var audioBridge: ScreenAudioMixProcessor? = null

        @JvmStatic
        fun feedSystemAudio(buf: ShortArray, n: Int) {
            audioBridge?.writeCaptureSamples(buf, n)
        }
    }
}
