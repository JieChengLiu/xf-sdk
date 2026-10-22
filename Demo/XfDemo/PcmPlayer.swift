import AVFoundation

/// 边收边播 16kHz / 16bit / 单声道 PCM（会话 config 里 outputFormat = "pcm"）。
/// 每个分片转成 Float32 buffer 排进 AVAudioPlayerNode，混音器负责重采样到硬件采样率。
/// 只在主线程调用。
final class PcmPlayer {

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    // 分片边界可能把一个 16bit 采样劈开，剩下的半个字节留到下一片
    private var carry: UInt8?

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    func enqueue(_ pcm: Data) {
        var bytes = [UInt8](pcm)
        if let carry = carry {
            bytes.insert(carry, at: 0)
            self.carry = nil
        }
        if bytes.count % 2 == 1 { carry = bytes.removeLast() }
        let frames = bytes.count / 2
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            let sample = Int16(bitPattern: UInt16(bytes[2 * i]) | UInt16(bytes[2 * i + 1]) << 8)
            channel[i] = Float(sample) / 32768
        }

        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                return
            }
        }
        node.scheduleBuffer(buffer, completionHandler: nil)
        if !node.isPlaying { node.play() }
    }

    /// 立即停播并丢弃队列（收到 audioInterrupt 时调用）
    func flush() {
        carry = nil
        // stop 会清掉所有已排队的 buffer
        node.stop()
    }
}
