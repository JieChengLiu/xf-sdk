package com.xfusion.sdk.demo

import com.xfusion.sdk.stream.RawOpusPacketSplitter
import io.github.jaredmdobson.concentus.OpusDecoder

/**
 * 把 outputFormat = "opus" 的 TTS 裸流解成 16kHz / 16bit / 单声道 PCM，交给 PcmPlayer 播放。
 *
 * 容易踩的三个坑（都会表现为"播放加速"）：
 * 1. 不切包：一个 TtsAudio 分片里是多个 80 字节的包首尾相接，整片当一个包解只得到前 20ms。
 * 2. 输出缓冲太小：framesPerPacket = 4 时一包是 80ms = 1280 个采样，按 320 分配会失败或被截断。
 * 3. 采样率/声道不一致：解码器和 AudioTrack 都必须是 16000Hz、单声道。
 *
 * 每路 TTS 流用一个实例，不是线程安全的。
 */
class OpusTtsDecoder(framesPerPacket: Int = 4) {

    private val splitter = RawOpusPacketSplitter(framesPerPacket = framesPerPacket)
    private val decoder = OpusDecoder(SAMPLE_RATE, 1)
    // Opus 单包最长 120ms，按上限分配，不管 framesPerPacket 设多少都够
    private val pcm = ShortArray(MAX_FRAME_SAMPLES)

    /** 本句已解出的采样数，用来核对时长：正常应等于 包内帧数 × 320 */
    var sentenceSamples = 0L
        private set
    var sentencePackets = 0
        private set
    var sentenceErrors = 0
        private set

    /** 喂一个 TtsAudio 分片，返回解出的 PCM（小端 16bit），可能为空 */
    fun feed(chunk: ByteArray): ByteArray = decodeAll(splitter.feed(chunk))

    /** 句子结束（TtsComplete）时调用，取出组包剩下的帧 */
    fun flush(): ByteArray = decodeAll(splitter.flush())

    /** 打断（AudioInterrupt）或开始新一句时调用 */
    fun reset() {
        splitter.reset()
        decoder.resetState()
        resetStats()
    }

    fun resetStats() {
        sentenceSamples = 0
        sentencePackets = 0
        sentenceErrors = 0
    }

    private fun decodeAll(packets: List<ByteArray>): ByteArray {
        if (packets.isEmpty()) return EMPTY
        val out = java.io.ByteArrayOutputStream(packets.size * MAX_FRAME_SAMPLES / 2)
        for (packet in packets) {
            val samples = try {
                // frame_size 传整个缓冲长度：多帧包会一次解出全部帧，不会只取前 20ms
                decoder.decode(packet, 0, packet.size, pcm, 0, pcm.size, false)
            } catch (e: Exception) {
                sentenceErrors++
                continue
            }
            sentencePackets++
            sentenceSamples += samples
            for (i in 0 until samples) {
                val s = pcm[i].toInt()
                out.write(s and 0xFF)
                out.write((s shr 8) and 0xFF)
            }
        }
        return out.toByteArray()
    }

    companion object {
        const val SAMPLE_RATE = 16000
        // Opus 规范里单包的最大采样数（48kHz 下 120ms）；16kHz 实际最多 1920，按规范上限分配最省心
        private const val MAX_FRAME_SAMPLES = 5760
        private val EMPTY = ByteArray(0)
    }
}
