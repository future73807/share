package com.future.screenShare

import android.util.Log
import com.cloudwebrtc.webrtc.audio.AudioProcessingAdapter
import java.nio.ByteBuffer

/**
 * WebRTC 采集后处理(capturePostProcessing)音频处理器。
 *
 * flutter_webrtc 的麦克风链路: AudioRecord(VOICE_COMMUNICATION, 硬件 AEC/NS)
 *   -> capturePostProcessing(本处理器) -> WebRTC APM -> 编码发送。
 *
 * 本处理器根据声音分享模式改写采集缓冲:
 *  - MODE_MIC        : 原样透传麦克风(硬件回声抑制生效);
 *  - MODE_SCREEN     : 整体替换为屏幕内部声音(AudioPlaybackCapture 采集);
 *  - MODE_MIXED      : 麦克风 + 屏幕内部声音叠加(饱和截断);
 *  - MODE_NONE       : 全部置零(静音);
 *  - MODE_PASSTHROUGH: 透传。换源模式(仅屏幕声音/混合)下 ADM 采集源已被
 *      换成 VirtualAudioRecord——仅屏幕声音交付系统内录,混合交付
 *      "系统内录+麦克风自采"的叠加,缓冲内容即为最终上行,处理链
 *      不得再消费环形缓冲(否则与虚拟音源双消费导致欠载)。
 *
 * 注意:麦克风轨道是所有模式的音频"载体"——共享期间必须保持
 * getUserMedia 麦克风流处于活跃状态;但换源模式下物理麦克风由
 * VirtualAudioRecord 接管(混合模式的麦克风内容来自插件自采线程),
 * 软件注入链路仅作换源失败时的兜底。
 */
class ScreenAudioMixProcessor : AudioProcessingAdapter.ExternalAudioFrameProcessing {

    companion object {
        const val MODE_NONE = 0
        const val MODE_MIC = 1
        const val MODE_SCREEN = 2
        const val MODE_MIXED = 3
        const val MODE_PASSTHROUGH = 4

        // 系统音频采集采样率(源);16k 为 CSDN 实测兼容方案,
        // 部分机型(MIUI 等)在 48k 下 AudioPlaybackCapture 只会采到静音
        const val SRC_SAMPLE_RATE = 16000

        private const val RING_CAPACITY = SRC_SAMPLE_RATE * 2 // 2 秒
    }

    /** 当前混音模式,由插件线程写入、WebRTC 音频线程读取 */
    @Volatile
    var mode: Int = MODE_MIC

    /** 是否已注册到 flutter_webrtc */
    @Volatile
    var registered: Boolean = false

    /** 屏幕音频环形缓冲(生产者:采集线程;消费者:WebRTC 音频线程) */
    val ring = RingBuffer(RING_CAPACITY)

    /** 麦克风自采环形缓冲(混合模式换源时,VirtualAudioRecord 从这里取麦克风样本) */
    val micRing = RingBuffer(RING_CAPACITY)

    /** 混合模式虚拟源开关:true=虚拟音源交付时叠加 micRing(混合);false=仅屏幕内音 */
    @Volatile
    var virtualMixMic: Boolean = false

    // 目标(WebRTC 处理)采样率/声道,在 initialize 中回调给出
    private var targetRate = SRC_SAMPLE_RATE
    private var targetChannels = 1
    // 跨块采样率换算累加器:每块应消耗 源率/目标率*帧数 个源样本,分数部分累计到下一块
    private var srcAcc = 0.0
    private var logTick = 0

    /** 最近一块送入编码的音频峰值(0..32767),供 UI 电平条轮询 */
    @Volatile
    var lastOutPeak: Int = 0
        private set

    /** 最近一块内录采集的原始峰值(0..32767):无人观看时电平条用它与 lastOutPeak 取大 */
    @Volatile
    var capturePeak: Int = 0
        private set

    /** 内录采集线程产出的样本数累计(Dart 侧用差值判断采集是否存活)。
     *  注意:计数的是"生产"而非"消费"——消费依赖 WebRTC 会话,房间无观众时
     *  采集循环不运行,按消费计数会把正常共享误报为"屏幕内音无数据";
     *  内录线程独立于观众,只要手机在放声音就有产出。 */
    @Volatile
    var captureWrites: Int = 0
        private set

    override fun initialize(sampleRateHz: Int, numChannels: Int) {
        targetRate = if (sampleRateHz > 0) sampleRateHz else SRC_SAMPLE_RATE
        targetChannels = if (numChannels > 0) numChannels else 1
        srcAcc = 0.0
        Log.d("ScreenAudioMix", "initialize rate=$targetRate channels=$targetChannels")
    }

    override fun reset(newRate: Int) {
        srcAcc = 0.0
    }

    /** 采集线程写入 PCM16 单声道样本(生产侧:这里计数,与观众有无无关) */
    fun writeCaptureSamples(buf: ShortArray, count: Int) {
        ring.write(buf, count)
        var p = 0
        for (i in 0 until count) {
            val a = Math.abs(buf[i].toInt())
            if (a > p) p = a
        }
        capturePeak = p
        captureWrites += count
    }

    /** 麦克风自采线程写入 PCM16 单声道样本(混合模式虚拟源用) */
    fun writeMicSamples(buf: ShortArray, count: Int) {
        micRing.write(buf, count)
    }

    /** 虚拟音源(VirtualAudioRecord)交付的上报:送入编码的峰值(电平条用) */
    fun reportVirtualDelivery(peak: Int) {
        lastOutPeak = peak
    }

    override fun process(numBands: Int, numFrames: Int, buffer: ByteBuffer) {
        val tick = logTick++
        if (tick < 3) {
            Log.d("ScreenAudioMix", "process 被调用 #$tick mode=$mode frames=$numFrames")
        }
        when (mode) {
            MODE_MIC, MODE_PASSTHROUGH -> return
            MODE_NONE -> {
                buffer.rewind()
                while (buffer.hasRemaining()) buffer.put(0)
                return
            }
            else -> {}
        }
        val frames = numBands * numFrames
        if (frames <= 0) return
        buffer.rewind()
        if (buffer.remaining() < frames * targetChannels * 2) return

        // 本块应消耗的源样本数(分数部分跨块累加,长期速率精确,不会变调)
        srcAcc += frames.toDouble() * SRC_SAMPLE_RATE / targetRate
        val take = srcAcc.toInt().coerceAtLeast(2)
        srcAcc -= take

        // 取源样本:缓冲不足时补零(表现为轻微静音间隙,优于变调)
        val src = ShortArray(take)
        val got = ring.read(src, 0, take)

        // 统计源电平(屏幕内音采集到的真实强度)与输出电平(送入编码的强度)
        var inPeak = 0
        var outPeak = 0
        for (i in 0 until got) {
            val a = Math.abs(src[i].toInt())
            if (a > inPeak) inPeak = a
        }
        if (tick % 100 == 0) {
            Log.d("ScreenAudioMix",
                "mode=$mode take=$take got=$got 源峰值=$inPeak ring可用=${ring.available()}")
        }

        buffer.order(java.nio.ByteOrder.LITTLE_ENDIAN)
        val denom = (numFrames - 1).coerceAtLeast(1)
        for (band in 0 until numBands) {
            for (j in 0 until numFrames) {
                // 源样本线性插值到输出帧
                val pos = j.toDouble() * (take - 1) / denom
                val i0 = pos.toInt()
                val frac = (pos - i0).toFloat()
                val i1 = (i0 + 1).coerceAtMost(take - 1)
                var v = src[i0] * (1f - frac) + src[i1] * frac
                var out = 0
                if (mode == MODE_MIXED) {
                    val p = buffer.position()
                    val mic = buffer.getShort(p).toInt()
                    out = (mic + v.toInt())
                        .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
                    buffer.putShort(p, out.toShort())
                    buffer.position(p + 2)
                } else { // MODE_SCREEN:整体替换
                    buffer.putShort(out.coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort())
                }
                val abs = Math.abs(out)
                if (abs > outPeak) outPeak = abs
            }
        }
        lastOutPeak = outPeak
    }

    /** 简单的 PCM16 环形缓冲 */
    class RingBuffer(private val capacity: Int) {
        private val data = ShortArray(capacity)
        private var writePos = 0L
        private var readPos = 0L

        @Synchronized
        fun write(buf: ShortArray, count: Int) {
            if (count <= 0) return
            // 缓冲满时丢弃最旧数据
            val available = writePos - readPos
            if (available + count > capacity) {
                readPos = writePos + count - capacity
            }
            var w = (writePos % capacity).toInt()
            for (i in 0 until count) {
                data[w] = buf[i]
                w = (w + 1) % capacity
            }
            writePos += count
        }

        /** 顺序读取 count 个样本,不足部分补 0,返回实际读到的有效样本数 */
        @Synchronized
        fun read(out: ShortArray, offset: Int, count: Int): Int {
            if (count <= 0) return 0
            val available = (writePos - readPos).toInt().coerceAtMost(count)
            var r = (readPos % capacity).toInt()
            for (i in 0 until count) {
                out[offset + i] = if (i < available) data[r] else 0
                if (i < available) {
                    r = (r + 1) % capacity
                }
            }
            readPos += available
            return available
        }

        @Synchronized
        fun available(): Int = (writePos - readPos).toInt()

        @Synchronized
        fun clear() {
            readPos = writePos
        }
    }
}
