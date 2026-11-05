import Foundation

/// 把 `outputFormat = "opus"` 下发的 TTS 裸流切成 Opus 包，供接入方逐包解码、边收边播。
///
/// 服务端转发的是 Azure `audio-16khz-16bit-32kbps-mono-opus`：每包固定 `packetBytes`（默认 80 字节，
/// 即 32kbps × 20ms），多个包首尾相接放在一个 `.ttsAudio` 的 `audio` 里，**没有长度前缀**。
/// 整块当成一个包送进解码器不会报错，但只解得出第一个 20ms，听起来断断续续。
///
/// `framesPerPacket` 大于 1 时，把连续的若干个 20ms 包按 Opus 标准（RFC 6716 §3.2）组装成一个多帧包，
/// 比如 4 → 每包 80ms、解码一次得到 1280 个采样，解码调用次数降到 1/4。只重排帧、不重新编码，
/// 解出来的声音与逐包解码逐采样一致；顺带去掉 Azure 为恒定码率塞的填充字节。一包最长 120ms。
///
/// 不足一个包的尾巴会留到下一次 `feed` 拼上，所以不依赖每块正好是 80 的整数倍。
///
///     let splitter = RawOpusPacketSplitter(framesPerPacket: 4)   // 每路 TTS 流一个（双屏 A、B 各一个）
///     case .ttsAudio(_, _, let audio): splitter.feed(audio).forEach(decodeAndPlay)
///     case .ttsComplete: splitter.flush().forEach(decodeAndPlay)  // 句尾不足 4 帧的部分
///     case .audioInterrupt: splitter.reset()
///
/// 不是线程安全的，在同一个回调队列里使用。
public final class RawOpusPacketSplitter {
    /// 服务端 `outputFormat = "opus"` 对应的每包字节数（16kHz、32kbps、20ms 一包）
    public static let defaultPacketBytes = 80
    /// 20ms 帧最多 6 个（Opus 单包上限 120ms）
    public static let maxFramesPerPacket = 6

    public let packetBytes: Int
    public let framesPerPacket: Int

    private var pending = [UInt8]()
    private var group: [[UInt8]] = []
    private var groupToc = -1
    private var groupDurationTenthsMs = 0

    public init(packetBytes: Int = RawOpusPacketSplitter.defaultPacketBytes, framesPerPacket: Int = 1) {
        precondition(packetBytes > 0, "packetBytes must be positive")
        precondition((1...RawOpusPacketSplitter.maxFramesPerPacket).contains(framesPerPacket),
                     "framesPerPacket must be 1...\(RawOpusPacketSplitter.maxFramesPerPacket)")
        self.packetBytes = packetBytes
        self.framesPerPacket = framesPerPacket
    }

    /// 上一次 `feed` 留下、还不够一个 `packetBytes` 的字节数
    public var pendingBytes: Int { pending.count }

    /// 已切出、还在等凑齐 `framesPerPacket` 的帧数；`flush` 会把它们组成一包输出
    public var pendingFrames: Int { group.count }

    /// 送入一块音频，返回其中已凑齐的完整包（可能为空）。
    public func feed(_ chunk: Data) -> [Data] {
        guard !chunk.isEmpty else { return [] }
        let bytes = pending + [UInt8](chunk)
        pending.removeAll(keepingCapacity: true)
        let count = bytes.count / packetBytes
        var out: [Data] = []
        for i in 0..<count {
            let packet = Array(bytes[(i * packetBytes)..<((i + 1) * packetBytes)])
            if framesPerPacket == 1 {
                out.append(Data(packet))
            } else {
                assemble(packet, into: &out)
            }
        }
        pending = Array(bytes[(count * packetBytes)...])
        return out
    }

    /// 把还没凑齐的帧组成一包输出。一句结束（`.ttsComplete`）时调用，避免句尾被压到下一句。
    public func flush() -> [Data] {
        var out: [Data] = []
        emitGroup(into: &out)
        return out
    }

    /// 丢弃未凑齐的字节和帧。打断（`.audioInterrupt`）时调用，避免旧句拼到新句。
    public func reset() {
        pending.removeAll()
        clearGroup()
    }

    private func assemble(_ packet: [UInt8], into out: inout [Data]) {
        guard let frames = OpusPacket.frames(packet) else {
            // 解析不了就原样放行，不冒险改动
            emitGroup(into: &out)
            out.append(Data(packet))
            return
        }
        let toc = Int(packet[0]) & 0xFC   // config + stereo，同一包内必须一致
        let frameTenthsMs = OpusPacket.frameDurationTenthsMs(Int(packet[0]))
        for frame in frames {
            if !group.isEmpty && (toc != groupToc
                    || groupDurationTenthsMs + frameTenthsMs > OpusPacket.maxPacketTenthsMs) {
                emitGroup(into: &out)
            }
            if group.isEmpty { groupToc = toc }
            group.append(frame)
            groupDurationTenthsMs += frameTenthsMs
            if group.count == framesPerPacket { emitGroup(into: &out) }
        }
    }

    private func emitGroup(into out: inout [Data]) {
        guard !group.isEmpty else { return }
        out.append(Data(OpusPacket.build(tocBase: groupToc, frames: group)))
        clearGroup()
    }

    private func clearGroup() {
        group.removeAll()
        groupToc = -1
        groupDurationTenthsMs = 0
    }
}

/// RFC 6716 §3.2 Opus 包的帧拆分与多帧组装。只处理包结构，不做编解码。与 Android `OpusPacket` 逐字节一致。
enum OpusPacket {
    static let maxPacketTenthsMs = 1200

    /// 拆出包里的各帧（不含填充）；结构不合法返回 nil。
    static func frames(_ packet: [UInt8]) -> [[UInt8]]? {
        guard !packet.isEmpty else { return nil }
        let toc = Int(packet[0])
        let size = packet.count
        switch toc & 0x03 {
        case 0:
            return [Array(packet[1..<size])]
        case 1:
            guard (size - 1) % 2 == 0 else { return nil }
            let half = (size - 1) / 2
            return [Array(packet[1..<(1 + half)]), Array(packet[(1 + half)..<size])]
        case 2:
            guard let length = readLength(packet, 1) else { return nil }
            let len = length.value, start = 1 + length.used
            guard start + len <= size else { return nil }
            return [Array(packet[start..<(start + len)]), Array(packet[(start + len)..<size])]
        default:
            return code3Frames(packet)
        }
    }

    private static func code3Frames(_ packet: [UInt8]) -> [[UInt8]]? {
        guard packet.count >= 2 else { return nil }
        let header = Int(packet[1])
        let vbr = header & 0x80 != 0
        let padded = header & 0x40 != 0
        let count = header & 0x3F
        guard count > 0 else { return nil }
        var pos = 2
        var padding = 0
        if padded {
            while true {
                guard pos < packet.count else { return nil }
                let b = Int(packet[pos]); pos += 1
                padding += b == 255 ? 254 : b
                if b != 255 { break }
            }
        }
        let end = packet.count - padding
        guard end >= pos else { return nil }
        var lengths = [Int](repeating: 0, count: count)
        if vbr {
            var sum = 0
            for i in 0..<(count - 1) {
                guard let length = readLength(packet, pos) else { return nil }
                pos += length.used
                lengths[i] = length.value
                sum += length.value
            }
            let last = end - pos - sum
            guard last >= 0 else { return nil }
            lengths[count - 1] = last
        } else {
            let total = end - pos
            guard total % count == 0 else { return nil }
            lengths = [Int](repeating: total / count, count: count)
        }
        var frames: [[UInt8]] = []
        for len in lengths {
            guard pos + len <= end else { return nil }
            frames.append(Array(packet[pos..<(pos + len)]))
            pos += len
        }
        return frames
    }

    /// 多帧包：code 3、VBR、无填充。单帧时用 code 0。
    static func build(tocBase: Int, frames: [[UInt8]]) -> [UInt8] {
        if frames.count == 1 { return [UInt8(tocBase)] + frames[0] }
        var out: [UInt8] = [UInt8(tocBase | 0x03), UInt8(0x80 | frames.count)]
        for frame in frames.dropLast() { writeLength(&out, frame.count) }
        for frame in frames { out += frame }
        return out
    }

    /// TOC 里每帧时长，单位 0.1ms
    static func frameDurationTenthsMs(_ toc: Int) -> Int {
        let config = toc >> 3
        if config < 12 { return [100, 200, 400, 600][config & 3] }   // SILK
        if config < 16 { return [100, 200][config & 1] }             // Hybrid
        return [25, 50, 100, 200][config & 3]                        // CELT
    }

    private static func readLength(_ data: [UInt8], _ pos: Int) -> (value: Int, used: Int)? {
        guard pos < data.count else { return nil }
        let b0 = Int(data[pos])
        if b0 < 252 { return (b0, 1) }
        guard pos + 1 < data.count else { return nil }
        return (b0 + 4 * Int(data[pos + 1]), 2)
    }

    private static func writeLength(_ out: inout [UInt8], _ len: Int) {
        if len < 252 {
            out.append(UInt8(len))
        } else {
            let b0 = 252 + ((len - 252) & 0x03)
            out.append(UInt8(b0))
            out.append(UInt8((len - b0) >> 2))
        }
    }
}
