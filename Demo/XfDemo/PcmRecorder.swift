import AVFoundation

/// 麦克风采集并转成 16kHz / 16bit / 单声道小端 PCM，正是 SDK sendPCM 要的格式。
/// 硬件采样率一般是 48kHz，用 AVAudioConverter 重采样。回调在音频线程上。
final class PcmRecorder {

    enum RecorderError: Error {
        case noInput
        case converterUnavailable
    }

    private let engine = AVAudioEngine()
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private(set) var isRunning = false

    /// onPCM 在音频线程调用，标 @Sendable 免得被推断成主线程隔离
    func start(onPCM: @escaping @Sendable (Data) -> Void) throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        // 模拟器没有可用麦克风时采样率是 0
        guard inputFormat.sampleRate > 0 else { throw RecorderError.noInput }
        guard let converter = AVAudioConverter(from: inputFormat, to: target) else { throw RecorderError.converterUnavailable }
        let target = self.target

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / inputFormat.sampleRate) + 1
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, output.frameLength > 0, let samples = output.int16ChannelData else { return }
            onPCM(Data(bytes: samples[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size))
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }
}
