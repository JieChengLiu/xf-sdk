package com.xfusion.sdk.demo

import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * 边收边播 16kHz / 16bit / 单声道 PCM（会话 config 里 outputFormat = "pcm"）。
 * AudioTrack.write 会阻塞，放在单独线程；flush 用代数作废已排队但还没写入的分片。
 */
class PcmPlayer {

    private val writer = Executors.newSingleThreadExecutor { Thread(it, "pcm-player") }
    private val generation = AtomicInteger()
    // 分片边界可能把一个 16bit 采样劈开，剩下的半个字节留到下一片
    private var carry: Byte? = null

    @Suppress("DEPRECATION") // AudioTrack.Builder 要 API 23，demo 支持到 21
    private val track = AudioTrack(
        AudioManager.STREAM_MUSIC, SAMPLE_RATE,
        AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT,
        maxOf(AudioTrack.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT), SAMPLE_RATE),
        AudioTrack.MODE_STREAM,
    ).apply { play() }

    fun enqueue(pcm: ByteArray) {
        val gen = generation.get()
        writer.execute {
            if (gen != generation.get()) return@execute
            val pending = carry
            val data = if (pending == null) pcm else byteArrayOf(pending) + pcm
            val even = data.size - data.size % 2
            carry = if (even < data.size) data[even] else null
            if (even > 0) track.write(data, 0, even)
        }
    }

    /** 立即停播并丢弃队列（收到 AudioInterrupt 时调用） */
    fun flush() {
        generation.incrementAndGet()
        writer.execute {
            carry = null
            track.pause()
            track.flush()
            track.play()
        }
    }

    fun release() {
        generation.incrementAndGet()
        writer.execute {
            runCatching { track.stop() }
            track.release()
        }
        writer.shutdown()
    }

    private companion object {
        const val SAMPLE_RATE = 16000
    }
}
