import Foundation

/// 原始 Opus 包的二进制封装，与服务端 RawOpusFrameProtocol 对齐：
///
///     0..3   magic      "XOP1"
///     4      version    1
///     5      flags      bit0 = endOfTurn
///     6      headerLen  20
///     7      frameMs    通常 20
///     8..11  seq        uint32 big-endian
///     12..19 timestamp  uint64 big-endian，距流开始的毫秒数
///     20..n  payload    一个 Opus 包
public enum Xop1Frame {
    public static let headerLength = 20

    public static func wrap(_ opusPacket: Data, seq: UInt32, timestampMs: UInt64,
                            frameMs: UInt8 = 20, endOfTurn: Bool = false) -> Data {
        precondition(!opusPacket.isEmpty, "empty opus packet")
        var frame = Data(capacity: headerLength + opusPacket.count)
        frame.append(contentsOf: Array("XOP1".utf8))
        frame.append(1)                         // version
        frame.append(endOfTurn ? 1 : 0)         // flags
        frame.append(UInt8(headerLength))
        frame.append(frameMs)
        withUnsafeBytes(of: seq.bigEndian) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: timestampMs.bigEndian) { frame.append(contentsOf: $0) }
        frame.append(opusPacket)
        return frame
    }
}
