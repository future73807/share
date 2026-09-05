package com.future.screenShare

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * "虚拟录音器":替换 WebRTC ADM 中 WebRtcAudioRecord.audioRecord 字段里的
 * 物理 AudioRecord,使"仅屏幕声音"模式下麦克风硬件不被打开、不被采集。
 *
 * WebRTC 的 AudioRecordThread 每 10ms 调一次 read(ByteBuffer, sizeInBytes)
 * 并断言返回值等于缓冲容量;本类从系统内录环形缓冲
 * (ScreenAudioMixProcessor.ring,16k 单声道 PCM16)取数,分数累加 + 线性
 * 插值重采样到 ADM 的目标格式(bypassVoiceProcessing 下典型 48k 立体声),
 * 整块填满后原样返回。
 *
 * 首次成功交付时把混音处理器从 MODE_SCREEN(替换)翻成 MODE_PASSTHROUGH,
 * 避免处理链再次消费同一环形缓冲(双消费会欠载变调)。
 *
 * 注意:父类构造出的 AudioRecord(MIC 源)只是占位,从不 startRecording,
 * 不会点亮麦克风;真正数据源是插件内录线程喂的环形缓冲。
 */
class VirtualAudioRecord(
    private val processor: ScreenAudioMixProcessor,
    private val targetRate: Int,
    private val targetChannels: Int
) : AudioRecord(
    MediaRecorder.AudioSource.MIC,
    48000,
    AudioFormat.CHANNEL_IN_STEREO,
    AudioFormat.ENCODING_PCM_16BIT,
    AudioRecord.getMinBufferSize(
        48000, AudioFormat.CHANNEL_IN_STEREO, AudioFormat.ENCODING_PCM_16BIT
    ).coerceAtLeast(4096)
) {

    /** 恢复麦克风失败等异常场景置 true:交付静音,环形缓冲留给处理链(混音模式) */
    @Volatile
    var deliverSilence = false

    /** 跨块采样率换算累加器:每块消耗 源率/目标率*帧数 个源样本,分数部分累计 */
    private var srcAcc = 0.0
    private var scratch = ShortArray(8192)
    private val srcRate = ScreenAudioMixProcessor.SRC_SAMPLE_RATE

    private val bytesPerFrame = 2 * targetChannels

    // 节流调度:真实 AudioRecord.read 会阻塞约一个块周期,WebRTC 采集循环
    // 靠这个阻塞节流;虚拟源若立即返回,循环将以 CPU 极限空转,把上百倍
    // 实时速率灌进 native 发送管线(nativeDataIsRecorded→APM→RTP),
    // 数秒内耗尽地址空间(实测 Scudo OOM/SIGABRT)。必须按块时长放行。
    private var nextDueNs = 0L

    companion object {
        @Volatile private var diagBlocks = 0L
        private fun diagLog() {
            val maps = try {
                java.io.File("/proc/self/maps").readLines().size
            } catch (_: Throwable) { -1 }
            android.util.Log.i("VirtualAudioDiag",
                "blocks=$diagBlocks nativeHeap=${android.os.Debug.getNativeHeapAllocatedSize() / 1048576}MB maps=$maps")
        }
    }

    override fun getRecordingState(): Int = AudioRecord.RECORDSTATE_RECORDING

    override fun getState(): Int = AudioRecord.STATE_INITIALIZED

    override fun startRecording() {
        // ADM 不会对我们调用(换源发生在其启动之后);仅维持状态语义
    }

    override fun stop() {}

    override fun release() {}

    override fun read(audioBuffer: ByteBuffer, sizeInBytes: Int): Int {
        if (sizeInBytes <= 0) return AudioRecord.ERROR_BAD_VALUE
        val frames = sizeInBytes / bytesPerFrame
        if (frames <= 0) return sizeInBytes
        pace(frames)

        val buf = audioBuffer

        buf.order(ByteOrder.LITTLE_ENDIAN)
        if (deliverSilence) {
            buf.rewind()
            while (buf.hasRemaining()) buf.put(0)
            return sizeInBytes
        }

        if (scratch.size < frames + 2) scratch = ShortArray(frames + 2)

        srcAcc += frames.toDouble() * srcRate / targetRate
        val take = srcAcc.toInt().coerceAtLeast(2)
        srcAcc -= take
        val src = scratch
        val got = processor.ring.read(src, 0, take)

        val denom = (frames - 1).coerceAtLeast(1)
        var peak = 0
        buf.rewind()
        for (j in 0 until frames) {
            val pos = j.toDouble() * (take - 1) / denom
            val i0 = pos.toInt()
            val frac = (pos - i0).toFloat()
            val i1 = (i0 + 1).coerceAtMost(take - 1)
            val v = (src[i0] * (1f - frac) + src[i1] * frac).toInt()
                .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
            val abs = if (v < 0) -v else v
            if (abs > peak) peak = abs
            for (c in 0 until targetChannels) buf.putShort(v.toShort())
        }
        processor.reportVirtualDelivery(peak, got)
        // 换源完成后内容已是系统内音,处理链无需再做"替换"(避免双消费)
        if (processor.mode == ScreenAudioMixProcessor.MODE_SCREEN) {
            processor.mode = ScreenAudioMixProcessor.MODE_PASSTHROUGH
        }
        if (diagBlocks++ % 500L == 0L) diagLog()
        return frames * bytesPerFrame
    }

    /** 按块时长节流:把本块放行时刻钉在 10ms(块时长)节奏上,落后超过 3 块则重置节奏防突发 */
    private fun pace(frames: Int) {
        val blockNs = frames * 1_000_000_000L / targetRate
        val now = System.nanoTime()
        if (nextDueNs == 0L) {
            nextDueNs = now + blockNs
            return
        }
        val wait = nextDueNs - now
        if (wait > 0) {
            try {
                Thread.sleep(wait / 1_000_000, (wait % 1_000_000).toInt())
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }
        nextDueNs += blockNs
        if (nextDueNs < System.nanoTime() - blockNs * 3) {
            nextDueNs = System.nanoTime() + blockNs
        }
    }

    override fun read(audioData: ShortArray, offsetInShorts: Int, sizeInShorts: Int): Int {
        // WebRTC 采集线程只走 ByteBuffer 变体;此处防御性支持 short[] 变体(单声道语义)
        if (sizeInShorts <= 0) return AudioRecord.ERROR_BAD_VALUE
        val out = audioData
        if (deliverSilence) {
            for (i in 0 until sizeInShorts) out[offsetInShorts + i] = 0
            return sizeInShorts
        }
        if (scratch.size < sizeInShorts + 2) scratch = ShortArray(sizeInShorts + 2)
        val got = processor.ring.read(scratch, 0, sizeInShorts)
        var peak = 0
        for (i in 0 until sizeInShorts) {
            val v = scratch[i]
            val abs = if (v < 0) -v.toInt() else v.toInt()
            if (abs > peak) peak = abs
            out[offsetInShorts + i] = v
        }
        processor.reportVirtualDelivery(peak, got)
        if (processor.mode == ScreenAudioMixProcessor.MODE_SCREEN) {
            processor.mode = ScreenAudioMixProcessor.MODE_PASSTHROUGH
        }
        return sizeInShorts
    }
}
