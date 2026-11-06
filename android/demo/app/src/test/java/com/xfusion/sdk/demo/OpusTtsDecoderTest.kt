package com.xfusion.sdk.demo

import io.github.jaredmdobson.concentus.OpusDecoder
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.File

/** 用服务端真实转发的一整句 TTS（253 帧 × 20ms）核对解码时长，即"播放会不会变快"。 */
class OpusTtsDecoderTest {

    private val sentence: ByteArray = run {
        val json = File("../../../test-vectors/raw-opus-tts.json").readText()
        val hex = Regex("\"sentenceHex\"\\s*:\\s*\"([0-9a-fA-F]+)\"").find(json)!!.groupValues[1]
        ByteArray(hex.length / 2) { hex.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    }
    private val frames = sentence.size / 80
    private val expectedSamples = frames * 320L // 16kHz 下每帧 20ms = 320 个采样

    /** 分片边界故意不对齐 80 字节，模拟网络分片 */
    private fun decode(framesPerPacket: Int): Pair<OpusTtsDecoder, ByteArray> {
        val decoder = OpusTtsDecoder(framesPerPacket)
        val out = ByteArrayOutputStream()
        val sizes = intArrayOf(37, 163, 300, 1, 499, 280)
        var offset = 0
        var i = 0
        while (offset < sentence.size) {
            val end = minOf(sentence.size, offset + sizes[i++ % sizes.size])
            out.write(decoder.feed(sentence.copyOfRange(offset, end)))
            offset = end
        }
        out.write(decoder.flush())
        return decoder to out.toByteArray()
    }

    @Test
    fun multiFramePacketsDecodeToFullSentenceDuration() {
        val (decoder, pcm) = decode(framesPerPacket = 4)
        assertEquals(253, frames)
        assertEquals(0, decoder.sentenceErrors)
        assertEquals(expectedSamples, decoder.sentenceSamples)
        assertEquals(expectedSamples * 2, pcm.size.toLong())
        assertEquals((frames + 3) / 4, decoder.sentencePackets)
    }

    @Test
    fun outputIsIdenticalForAnyFramesPerPacket() {
        val single = decode(framesPerPacket = 1).second
        for (n in 2..6) assertArrayEquals("framesPerPacket=$n", single, decode(n).second)
    }

    /** 反例：不切包、整片当一个包解（客户最可能的写法），时长只剩一小部分，听起来就是"加速/跳字" */
    @Test
    fun decodingWholeChunksWithoutSplittingLosesMostAudio() {
        val decoder = OpusDecoder(16000, 1)
        val buf = ShortArray(5760)
        var samples = 0L
        var offset = 0
        while (offset < sentence.size) {
            val end = minOf(sentence.size, offset + 400) // 服务端常见分片：5 个包
            samples += runCatching { decoder.decode(sentence, offset, end - offset, buf, 0, buf.size, false) }
                .getOrDefault(0)
            offset = end
        }
        assertTrue("got $samples of $expectedSamples", samples <= expectedSamples / 4)
    }
}
