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
 *  - MODE_MIC    : 原样透传麦克风(硬件回声抑制生效);
 *  - MODE_SCREEN : 整体替换为屏幕内部声音(AudioPlaybackCapture 采集);
 *  - MODE_MIXED  : 麦克风 + 屏幕内部声音叠加(饱和截断);
 *  - MODE_NONE   : 全部置零(静音)。
 */
class ScreenAudioMixProcessor : AudioProcessingAdapter.ExternalAudioFrameProcessing {

    companion object {
        const val MODE_NONE = 0
        const val MODE_MIC = 1
        const val MODE_SCREEN = 2
        const val MODE_MIXED = 3

        // 系统音频采集采样率(源)
        const val SRC_SAMPLE_RATE = 48000

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

    // 目标(WebRTC 处理)采样率/声道,在 initialize 中回调给出
    private var targetRate = SRC_SAMPLE_RATE
    private var targetChannels = 1
    // 块间重采样余量
    private val carry = ArrayList<Short>()

    override fun initialize(sampleRateHz: Int, numChannels: Int) {
        targetRate = if (sampleRateHz > 0) sampleRateHz else SRC_SAMPLE_RATE
        targetChannels = if (numChannels > 0) numChannels else 1
        reset(targetRate)
        Log.d("ScreenAudioMix", "initialize rate=$targetRate channels=$targetChannels")
    }

    override fun reset(newRate: Int) {
        synchronized(carry) { carry.clear() }
    }

    /** 采集线程写入 PCM16 单声道样本 */
    fun writeCaptureSamples(buf: ShortArray, count: Int) {
        ring.write(buf, count)
    }

    override fun process(numBands: Int, numFrames: Int, buffer: ByteBuffer) {
        when (mode) {
            MODE_MIC -> return // 透传,不动缓冲
            MODE_NONE -> {
                buffer.rewind()
                while (buffer.hasRemaining()) buffer.put(0)
                return
            }
            else -> {}
        }

        val totalSamples = numBands * numFrames * targetChannels
        if (totalSamples <= 0) return
        buffer.rewind()
        if (buffer.remaining() < totalSamples * 2) return

        // 1) 拉取一段源采样,并按 (srcRate -> targetRate) 线性重采样到每输出帧一组值
        val frameValues = FloatArray(numFrames)
        val srcNeeded = Math.max(2, (numFrames.toLong() * SRC_SAMPLE_RATE / targetRate + 2).toInt())
        val src = ShortArray(srcNeeded)
        val got = synchronized(carry) {
            var n = 0
            for (v in carry) { if (n < srcNeeded) { src[n++] = v } }
            carry.clear()
            n += ring.read(src, n, srcNeeded - n)
            n
        }
        if (got <= 0) {
            // 无屏幕音频(尚未开始播放等):按静音处理
            if (mode == MODE_SCREEN) {
                while (buffer.hasRemaining()) buffer.put(0)
                return
            }
            return
        }
        // 把已消费的剩余样本留到下一块,保证速率长期收敛
        val lastPos = (numFrames - 1).toDouble() * (got - 1) / Math.max(1, numFrames - 1)
        val consumed = Math.min(got - 1, Math.floor(lastPos).toInt() + 1)
        for (i in consumed until got) {
            synchronized(carry) { if (carry.size < 4096) carry.add(src[i]) }
        }
        for (j in 0 until numFrames) {
            val pos = j.toDouble() * (got - 1) / Math.max(1, numFrames - 1)
            val i0 = Math.floor(pos).toInt()
            val i1 = Math.min(i0 + 1, got - 1)
            val frac = (pos - i0).toFloat()
            frameValues[j] = src[i0] * (1f - frac) + src[i1] * frac
        }

        // 2) 写回缓冲:screen=替换;mixed=叠加(饱和截断)
        buffer.order(java.nio.ByteOrder.LITTLE_ENDIAN)
        if (mode == MODE_SCREEN) {
            for (band in 0 until numBands) {
                for (j in 0 until numFrames) {
                    val v = frameValues[j].toInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()
                    repeat(targetChannels) { buffer.putShort(v) }
                }
            }
        } else { // MODE_MIXED
            for (band in 0 until numBands) {
                for (j in 0 until numFrames) {
                    repeat(targetChannels) {
                        val mic = buffer.getShort(buffer.position()).toInt()
                        val mixed = (mic + frameValues[j].toInt())
                            .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
                        buffer.putShort(mixed.toShort())
                    }
                }
            }
        }
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

        /** 顺序读取 count 个样本,不足部分返回 0,返回实际读到的有效样本数 */
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
        fun clear() {
            readPos = writePos
        }
    }
}
