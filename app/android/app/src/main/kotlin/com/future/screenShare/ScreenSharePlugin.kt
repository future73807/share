package com.future.screenShare

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import org.webrtc.audio.JavaAudioDeviceModule
import java.lang.reflect.Field
import java.nio.ByteBuffer
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

    // ==== 仅屏幕声音模式:把 WebRTC ADM 的采集源从物理麦克风换成系统内录 ====
    // 原理:flutter_webrtc 的 JavaAudioDeviceModule 在音频轨道活跃时经
    // WebRtcAudioRecord 启动 AudioRecordThread 循环读取私有字段 audioRecord。
    // 我们向 recordSamplesReadyCallbackAdapter 注册回调——该回调在采集线程
    // 的两次 read 之间同步执行,此时换掉 audioRecord 字段没有任何竞态。
    // 换成 VirtualAudioRecord(数据来自 AudioPlaybackCapture 环形缓冲)后,
    // 原物理麦克风 AudioRecord 立即 stop+release,麦克风硬件不再被采集。

    /** 请求的声音模式("screen"/"mic"/"mixed"/"none"),Dart 经 setAudioShareMode 下发 */
    @Volatile private var requestedAudioMode: String = "mic"

    /** true = 需要把 ADM 采集源换成系统内录(仅屏幕声音且内录采集活跃) */
    @Volatile private var micBypassWanted = false

    private var samplesHookInstalled = false
    private var samplesAdapter: Any? = null
    private var samplesRemoveMethod: java.lang.reflect.Method? = null
    private var wrarHolder: Any? = null            // WebRtcAudioRecord 实例
    private var wrarRecordField: Field? = null     // 其私有 audioRecord 字段
    private var wrarBufferField: Field? = null     // 其私有 byteBuffer 字段(换源时清零防麦克风样音外泄)
    private var wrarSourceField: Field? = null     // 其私有 audioSource 字段(切回麦克风时重建用)
    private var virtualRecord: VirtualAudioRecord? = null
    private val admLock = Any()

    /** 恢复物理麦克风失败后置 true,避免采集线程上每 10ms 重试构造 AudioRecord */
    @Volatile private var micRestoreFailed = false

    // 原物理麦克风 AudioRecord 的构造参数(首次换源时记录,恢复麦克风时照抄)
    private var originalMicSaved = false
    private var originalMicSource = MediaRecorder.AudioSource.MIC
    private var originalMicRate = 48000
    private var originalMicMask = AudioFormat.CHANNEL_IN_STEREO
    private var originalMicEncoding = AudioFormat.ENCODING_PCM_16BIT

    /** 运行在 WebRTC 采集线程上,每个 10ms 块回调一次 */
    private val admSamplesHook = JavaAudioDeviceModule.SamplesReadyCallback {
        manageAdmSource()
    }

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
        detachAdmHook()
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
                requestedAudioMode = call.argument<String>("mode") ?: "mic"
                applyAudioMode()
                Log.i(TAG, "声音模式 -> $requestedAudioMode (micBypass=$micBypassWanted)")
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
                    "capturePeak" to mixProcessor.capturePeak,
                    "captureWrites" to mixProcessor.captureWrites,
                    "mode" to mixProcessor.mode,
                    "micFeed" to micFeedActive
                ))
            }
            "enterImmersive" -> {
                // 真·全屏:原生 WindowInsetsController 隐藏状态栏+导航栏。
                // SystemChrome 的 immersive 模式在部分系统(MIUI 等)会被覆盖失效。
                val act = activity
                if (act == null) {
                    result.success(false)
                    return
                }
                act.runOnUiThread {
                    try {
                        val w = act.window
                        val controller = w.insetsController
                        if (controller != null) {
                            controller.systemBarsBehavior =
                                android.view.WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                            controller.hide(android.view.WindowInsets.Type.systemBars())
                        } else {
                            @Suppress("DEPRECATION")
                            w.decorView.systemUiVisibility = (android.view.View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                                    or android.view.View.SYSTEM_UI_FLAG_FULLSCREEN
                                    or android.view.View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                                    or android.view.View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                                    or android.view.View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                                    or android.view.View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION)
                        }
                        w.statusBarColor = android.graphics.Color.BLACK
                        result.success(true)
                    } catch (t: Throwable) {
                        Log.e(TAG, "enterImmersive 失败", t)
                        result.success(false)
                    }
                }
            }
            "exitImmersive" -> {
                val act = activity
                if (act == null) {
                    result.success(false)
                    return
                }
                act.runOnUiThread {
                    try {
                        val w = act.window
                        w.insetsController?.show(android.view.WindowInsets.Type.systemBars())
                        @Suppress("DEPRECATION")
                        w.decorView.systemUiVisibility = android.view.View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                        w.statusBarColor = android.graphics.Color.TRANSPARENT
                        result.success(true)
                    } catch (t: Throwable) {
                        Log.e(TAG, "exitImmersive 失败", t)
                        result.success(false)
                    }
                }
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
        // 内录已活跃:若当前请求的是仅屏幕声音,现在才具备换源条件
        applyAudioMode()
    }

    private fun stopAudioCaptureInternal(releaseOwnProjection: Boolean) {
        audioCapturing = false
        audioRecord = null
        if (releaseOwnProjection) {
            try { ownProjection?.stop() } catch (_: Throwable) {}
            ownProjection = null
        }
        mixProcessor.ring.clear()
        applyAudioMode()
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

    /**
     * 声音模式生效:决定处理器模式与是否需要把 ADM 采集源换成系统内录。
     *
     * 仅屏幕声音与混合模式都走换源直供(micBypassWanted=true):虚拟源
     * 直接交付最终上行(混合=系统内录+麦克风自采叠加),由采集线程回调
     * 完成换源;处理器在换源未完成期间维持旧链路作为兜底(替换/软件注入),
     * 换源完成后由虚拟音源翻成 MODE_PASSTHROUGH。
     * 混合模式下同时启动麦克风自采线程,为虚拟源提供麦克风样本。
     */
    private fun applyAudioMode() {
        micBypassWanted =
            (requestedAudioMode == "screen" || requestedAudioMode == "mixed") && audioCapturing
        mixProcessor.virtualMixMic = requestedAudioMode == "mixed"
        if (requestedAudioMode == "mixed" && audioCapturing) {
            startMicFeed()
        } else {
            stopMicFeed()
        }
        mixProcessor.mode = when {
            // 虚拟源已接管上行:缓冲内容即最终混音,处理链透传
            micBypassWanted && virtualRecord != null ->
                ScreenAudioMixProcessor.MODE_PASSTHROUGH
            requestedAudioMode == "none" -> ScreenAudioMixProcessor.MODE_NONE
            requestedAudioMode == "screen" -> ScreenAudioMixProcessor.MODE_SCREEN
            requestedAudioMode == "mixed" -> ScreenAudioMixProcessor.MODE_MIXED
            else -> ScreenAudioMixProcessor.MODE_MIC
        }
        if (micBypassWanted) installAdmHook()
    }

    // ==== 混合模式麦克风自采线程 ====
    // 换源后 ADM 不再读物理麦克风,混合模式所需的麦克风样本由本线程
    // 独立采集(16k 单声道,与内录同格式,虚拟源在源级叠加)。
    // 非阻塞读 + 轮询:阻塞式 read 在部分机型(MIUI 并发采集限制)会
    // 永久挂起且无任何回调;持续无数据时自动轮换音频源重建录音器。
    private var micFeedRecord: AudioRecord? = null
    @Volatile private var micFeedActive = false
    private val micFeedStarting = java.util.concurrent.atomic.AtomicBoolean(false)

    private fun startMicFeed() {
        if (!micFeedStarting.compareAndSet(false, true)) return
        Thread {
            try {
                val sources = intArrayOf(
                    MediaRecorder.AudioSource.MIC,
                    MediaRecorder.AudioSource.VOICE_COMMUNICATION
                )
                val minBuf = AudioRecord.getMinBufferSize(
                    ScreenAudioMixProcessor.SRC_SAMPLE_RATE,
                    AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT
                ).coerceAtLeast(2048)
                val buf = ShortArray(1600) // 100ms
                var sourceIdx = 0
                var totalSamples = 0L
                var lastDataAt = 0L
                var loops = 0L
                var rec: AudioRecord? = null

                fun createRecorder(source: Int): AudioRecord? {
                    return try {
                        @SuppressLint("MissingPermission")
                        val candidate = AudioRecord(
                            source,
                            ScreenAudioMixProcessor.SRC_SAMPLE_RATE,
                            AudioFormat.CHANNEL_IN_MONO,
                            AudioFormat.ENCODING_PCM_16BIT,
                            minBuf * 4
                        )
                        if (candidate.state == AudioRecord.STATE_INITIALIZED) {
                            candidate
                        } else {
                            try { candidate.release() } catch (_: Throwable) {}
                            Log.w(TAG, "麦克风自采源 $source 初始化失败 state=${candidate.state}")
                            null
                        }
                    } catch (t: Throwable) {
                        Log.w(TAG, "麦克风自采源 $source 创建异常: ${t.message}")
                        null
                    }
                }

                try {
                    rec = createRecorder(sources[sourceIdx])
                    if (rec == null) {
                        Log.w(TAG, "麦克风自采线程: 所有音频源创建失败,混合模式将只有屏幕内音")
                        return@Thread
                    }
                    rec.startRecording()
                    micFeedRecord = rec
                    micFeedActive = true
                    Log.i(TAG, "麦克风自采线程启动 source=${sources[sourceIdx]}")

                    // 软件 AGC:原始麦克风电平通常远低于媒体声,叠加时会被掩盖。
                    // 目标块峰值 14000(约 -7dBFS),增益上限 6 倍,峰值窗 ~0.5s
                    // 衰减,增益平滑收敛避免忽大忽小。
                    var agcGain = 3f
                    var windowPeak = 0f
                    val agcTarget = 14000f

                    while (micFeedActive) {
                        val n = try {
                            rec!!.read(buf, 0, buf.size, AudioRecord.READ_NON_BLOCKING)
                        } catch (t: Throwable) {
                            Log.e(TAG, "麦克风自采 read 异常", t)
                            break
                        }
                        loops++
                        val now = SystemClock.elapsedRealtime()
                        if (n > 0) {
                            totalSamples += n
                            lastDataAt = now
                            var blockPeak = 0
                            for (i in 0 until n) {
                                val a = Math.abs(buf[i].toInt())
                                if (a > blockPeak) blockPeak = a
                            }
                            windowPeak = maxOf(blockPeak.toFloat(), windowPeak * 0.99f)
                            val desired = (agcTarget / maxOf(windowPeak, 250f))
                                .coerceIn(1f, 6f)
                            agcGain += (desired - agcGain) * 0.06f
                            if (agcGain > 1.02f) {
                                for (i in 0 until n) {
                                    buf[i] = (buf[i] * agcGain).toInt()
                                        .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
                                        .toShort()
                                }
                            }
                            mixProcessor.writeMicSamples(buf, n)
                        }
                        if (loops % 50L == 0L) {
                            Log.i(TAG, "麦克风自采: loops=$loops samples=$totalSamples " +
                                    "lastRead=$n recState=${rec!!.recordingState} " +
                                    "gain=${"%.2f".format(agcGain)} winPeak=${windowPeak.toInt()} " +
                                    "micRing可用=${mixProcessor.micRing.available()}")
                        }
                        // 持续 3 秒无数据:换下一个音频源重建录音器
                        if (lastDataAt in 1..(now - 3000)) {
                            sourceIdx = (sourceIdx + 1) % sources.size
                            Log.w(TAG, "麦克风自采 3 秒无数据,切换音频源 -> ${sources[sourceIdx]}")
                            try { rec!!.stop() } catch (_: Throwable) {}
                            try { rec!!.release() } catch (_: Throwable) {}
                            rec = createRecorder(sources[sourceIdx])
                            if (rec == null) {
                                Log.w(TAG, "重建录音器失败,自采线程退出")
                                break
                            }
                            rec!!.startRecording()
                            micFeedRecord = rec
                            lastDataAt = 0L
                        }
                        Thread.sleep(10)
                    }
                } finally {
                    micFeedActive = false
                    try { rec?.stop() } catch (_: Throwable) {}
                    try { rec?.release() } catch (_: Throwable) {}
                    micFeedRecord = null
                    Log.w(TAG, "麦克风自采线程退出 loops=$loops samples=$totalSamples")
                }
            } finally {
                micFeedStarting.set(false)
            }
        }.start()
    }

    private fun stopMicFeed() {
        micFeedActive = false
        // 录音器的 stop/release 在线程退出路径中执行,避免跨线程释放竞态
    }

    /** 轮询安装 ADM 采集源钩子(flutter_webrtc 可能晚于本插件初始化) */
    private fun installAdmHook() {
        if (samplesHookInstalled) return
        fun tryInstall(attempt: Int) {
            if (samplesHookInstalled || !micBypassWanted) return
            if (resolveAdmTargets()) return
            if (attempt < 20) {
                mainHandler.postDelayed({ tryInstall(attempt + 1) }, 250)
            } else {
                Log.w(TAG, "ADM 换源钩子安装超时,仅屏幕声音将走软件替换链路(麦克风仍会被采集)")
            }
        }
        tryInstall(0)
    }

    /**
     * 解析并挂接 flutter_webrtc 的 ADM 采集链:
     * sharedSingleton -> methodCallHandler.recordSamplesReadyCallbackAdapter(注册回调)
     *                 -> getUserMediaImpl.audioDeviceModule.audioInput(=WebRtcAudioRecord)
     *                 -> 其私有 audioRecord / byteBuffer / audioSource 字段
     */
    private fun resolveAdmTargets(): Boolean {
        if (samplesHookInstalled) return true
        return try {
            val singleton = FlutterWebRTCPlugin.sharedSingleton ?: return false
            val mch = singleton.javaClass.getDeclaredField("methodCallHandler")
                .apply { isAccessible = true }.get(singleton) ?: return false
            val adapter = try {
                mch.javaClass.getField("recordSamplesReadyCallbackAdapter").get(mch)
            } catch (_: Throwable) {
                null
            } ?: return false
            val gum = mch.javaClass.getDeclaredField("getUserMediaImpl")
                .apply { isAccessible = true }.get(mch) ?: return false
            val adm = try {
                gum.javaClass.getDeclaredField("audioDeviceModule")
                    .apply { isAccessible = true }.get(gum)
            } catch (_: Throwable) {
                null
            } ?: return false
            val audioInput = try {
                adm.javaClass.getField("audioInput").get(adm)
            } catch (_: Throwable) {
                null
            } ?: return false

            var recField: Field? = null
            var bufField: Field? = null
            var srcField: Field? = null
            var c: Class<*>? = audioInput.javaClass
            while (c != null) {
                if (recField == null) recField = try {
                    c!!.getDeclaredField("audioRecord").apply { isAccessible = true }
                } catch (_: NoSuchFieldException) { null }
                if (bufField == null) bufField = try {
                    c!!.getDeclaredField("byteBuffer").apply { isAccessible = true }
                } catch (_: NoSuchFieldException) { null }
                if (srcField == null) srcField = try {
                    c!!.getDeclaredField("audioSource").apply { isAccessible = true }
                } catch (_: NoSuchFieldException) { null }
                c = c.superclass
            }
            if (recField == null) {
                Log.w(TAG, "WebRtcAudioRecord.audioRecord 字段未找到")
                return false
            }

            val addMethod = adapter.javaClass.getMethod(
                "addCallback", JavaAudioDeviceModule.SamplesReadyCallback::class.java)
            addMethod.invoke(adapter, admSamplesHook)
            samplesRemoveMethod = try {
                adapter.javaClass.getMethod(
                    "removeCallback", JavaAudioDeviceModule.SamplesReadyCallback::class.java)
            } catch (_: Throwable) { null }
            samplesAdapter = adapter
            wrarHolder = audioInput
            wrarRecordField = recField
            wrarBufferField = bufField
            wrarSourceField = srcField
            samplesHookInstalled = true
            Log.i(TAG, "ADM 换源钩子已安装 (audioInput=${audioInput.javaClass.simpleName})")
            true
        } catch (t: Throwable) {
            Log.w(TAG, "解析 ADM 采集链失败: ${t.message}")
            false
        }
    }

    /** 运行在 WebRTC 采集线程:按当前期望源(audioRecord 字段)做换源/还原 */
    private fun manageAdmSource() {
        val holder = wrarHolder ?: return
        val field = wrarRecordField ?: return
        synchronized(admLock) {
            val cur = try {
                field.get(holder)
            } catch (_: Throwable) {
                return
            } ?: run {
                // ADM 已释放采集资源(会话结束),复位换源状态
                virtualRecord = null
                originalMicSaved = false
                return
            }
            if (micBypassWanted) {
                if (cur !== virtualRecord) swapToPlayback(holder, field, cur)
            } else if (cur === virtualRecord && !micRestoreFailed) {
                restoreMicRecord(holder, field)
            }
        }
    }

    /** 把物理麦克风 AudioRecord 换成虚拟内录音源,并立即关闭物理麦克风 */
    private fun swapToPlayback(holder: Any, field: Field, cur: Any) {
        val oldMic = cur as? AudioRecord ?: return
        try {
            val fmt = oldMic.format
            val rate = if (fmt.sampleRate > 0) fmt.sampleRate else originalMicRate
            val channels = Integer.bitCount(fmt.channelMask).coerceIn(1, 2)
            if (!originalMicSaved) {
                originalMicSource = try {
                    wrarSourceField?.getInt(holder) ?: MediaRecorder.AudioSource.MIC
                } catch (_: Throwable) {
                    MediaRecorder.AudioSource.MIC
                }
                originalMicRate = rate
                originalMicMask = fmt.channelMask
                originalMicEncoding = fmt.encoding
                originalMicSaved = true
            }
            val virtual = VirtualAudioRecord(mixProcessor, rate, channels)
            field.set(holder, virtual)
            virtualRecord = virtual
            micRestoreFailed = false
            // 清零本块已读入内存的麦克风样本:本回调返回后该块将被送出,
            // 清零确保换源瞬间没有任何麦克风内容外泄(回调处于两次 read 之间,
            // 且 nativeDataIsRecorded 尚未执行,清零是安全的)
            try {
                (wrarBufferField?.get(holder) as? ByteBuffer)?.let { b ->
                    b.rewind()
                    while (b.hasRemaining()) b.put(0)
                }
            } catch (_: Throwable) {}
            // 立即停掉物理麦克风(采集线程此刻不在读它,无竞态)
            try { oldMic.stop() } catch (_: Throwable) {}
            try { oldMic.release() } catch (_: Throwable) {}
            Log.i(TAG, "ADM 采集源已切换为系统内录,物理麦克风已停止 (rate=$rate ch=$channels)")
        } catch (t: Throwable) {
            Log.e(TAG, "ADM 换源失败,回退软件替换链路", t)
            micBypassWanted = false
        }
    }

    /** 从虚拟内录音源切回物理麦克风(仅屏幕声音 -> 麦克风/混合模式) */
    private fun restoreMicRecord(holder: Any, field: Field) {
        val virtual = virtualRecord ?: return
        try {
            val minBuf = AudioRecord.getMinBufferSize(
                originalMicRate, originalMicMask, originalMicEncoding
            ).coerceAtLeast(4096)
            @SuppressLint("MissingPermission")
            val mic = AudioRecord(
                originalMicSource, originalMicRate, originalMicMask,
                originalMicEncoding, minBuf * 2
            )
            if (mic.state != AudioRecord.STATE_INITIALIZED) {
                throw IllegalStateException("麦克风 AudioRecord state=${mic.state}")
            }
            mic.startRecording()
            field.set(holder, mic)
            virtualRecord = null
            Log.i(TAG, "ADM 采集源已恢复为物理麦克风 (rate=$originalMicRate)")
        } catch (t: Throwable) {
            // 恢复失败:虚拟源改为交付静音,把环形缓冲留给处理链(混音注入仍可用)
            Log.e(TAG, "恢复物理麦克风失败,虚拟源转为静音兜底", t)
            virtual.deliverSilence = true
            micRestoreFailed = true
        }
    }

    /** 引擎分离时摘除采集回调并清空反射缓存(防引擎重建后重复注册) */
    private fun detachAdmHook() {
        micBypassWanted = false
        virtualRecord = null
        originalMicSaved = false
        micRestoreFailed = false
        stopMicFeed()
        try {
            samplesRemoveMethod?.invoke(samplesAdapter, admSamplesHook)
        } catch (_: Throwable) {}
        samplesHookInstalled = false
        samplesAdapter = null
        samplesRemoveMethod = null
        wrarHolder = null
        wrarRecordField = null
        wrarBufferField = null
        wrarSourceField = null
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
