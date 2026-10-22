package com.xfusion.sdk.demo

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder

/** 16kHz / 16bit / 单声道麦克风采集，每 100ms 回调一次（3200 字节），正是 SDK sendPcm 要的格式 */
class PcmRecorder(private val onPcm: (buffer: ByteArray, length: Int) -> Unit) {

    @Volatile private var running = false
    private var thread: Thread? = null

    /** @return 麦克风是否打开成功（没有权限或被占用时返回 false） */
    fun start(): Boolean {
        if (running) return true
        val minBuffer = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (minBuffer <= 0) return false
        val record = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION, SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
                maxOf(minBuffer, CHUNK_BYTES * 4),
            )
        } catch (e: SecurityException) {
            return false
        }
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            return false
        }
        running = true
        thread = Thread({
            val buffer = ByteArray(CHUNK_BYTES)
            try {
                record.startRecording()
                while (running) {
                    val n = record.read(buffer, 0, buffer.size)
                    if (n > 0) onPcm(buffer, n)
                }
            } finally {
                runCatching { record.stop() }
                record.release()
            }
        }, "pcm-recorder").apply { start() }
        return true
    }

    fun stop() {
        running = false
        thread?.join(500)
        thread = null
    }

    companion object {
        const val SAMPLE_RATE = 16000
        const val CHUNK_BYTES = 3200
    }
}
