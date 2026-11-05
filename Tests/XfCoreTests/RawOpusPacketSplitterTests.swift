import XCTest
@testable import XfCore

/// 与 Android RawOpusPacketSplitterTest 共用 test-vectors/raw-opus-tts.json
final class RawOpusPacketSplitterTests: XCTestCase {

    private struct Vector {
        let data: Data
        let packetBytes: Int
        let serverChunks: [Int]
        let misalignedChunks: [Int]
        let expectedPackets: Int
        let firstTocByte: UInt8
        let sentence: Data
        let sentenceChunks: [Int]
        let assembledFrames: Int
        let assembledPackets: [Data]
    }

    private func loadVector() throws -> Vector {
        // 本仓库里在 sdk/test-vectors；导出成独立 Swift Package 仓库后在仓库根目录的 test-vectors
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // XfCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ios（或独立仓库根目录）
        let candidates = [
            packageRoot.appendingPathComponent("test-vectors/raw-opus-tts.json"),
            packageRoot.deletingLastPathComponent().appendingPathComponent("test-vectors/raw-opus-tts.json"),
        ]
        let url = try XCTUnwrap(candidates.first { FileManager.default.fileExists(atPath: $0.path) },
                                "raw-opus-tts.json not found")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let assembled = try XCTUnwrap(root["assembled"] as? [String: Any])
        return Vector(
            data: try decodeHex(try XCTUnwrap(root["dataHex"] as? String)),
            packetBytes: try XCTUnwrap(root["packetBytes"] as? Int),
            serverChunks: try XCTUnwrap(root["serverChunks"] as? [Int]),
            misalignedChunks: try XCTUnwrap(root["misalignedChunks"] as? [Int]),
            expectedPackets: try XCTUnwrap(root["expectedPackets"] as? Int),
            firstTocByte: UInt8(try XCTUnwrap(root["firstTocByte"] as? Int)),
            sentence: try decodeHex(try XCTUnwrap(root["sentenceHex"] as? String)),
            sentenceChunks: try XCTUnwrap(root["sentenceChunks"] as? [Int]),
            assembledFrames: try XCTUnwrap(assembled["framesPerPacket"] as? Int),
            assembledPackets: try XCTUnwrap(assembled["packetsHex"] as? [String]).map(decodeHex))
    }

    private func decodeHex(_ hex: String) throws -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(try XCTUnwrap(UInt8(hex[index..<next], radix: 16)))
            index = next
        }
        return Data(bytes)
    }

    private func chunks(_ data: Data, _ sizes: [Int]) -> [Data] {
        let bytes = [UInt8](data)
        var offset = 0
        return sizes.map { size in
            defer { offset += size }
            return Data(bytes[offset..<(offset + size)])
        }
    }

    private func split(_ splitter: RawOpusPacketSplitter, _ chunks: [Data]) -> [Data] {
        chunks.flatMap { splitter.feed($0) }
    }

    func testServerChunksSplitIntoConstantSizePackets() throws {
        let v = try loadVector()
        let packets = split(RawOpusPacketSplitter(packetBytes: v.packetBytes), chunks(v.data, v.serverChunks))

        XCTAssertEqual(packets.count, v.expectedPackets)
        XCTAssertTrue(packets.allSatisfy { $0.count == v.packetBytes })
        XCTAssertEqual(packets.first?.first, v.firstTocByte)
        XCTAssertEqual(packets.reduce(Data(), +), v.data)
    }

    func testMisalignedChunksYieldTheSamePackets() throws {
        let v = try loadVector()
        let expected = split(RawOpusPacketSplitter(packetBytes: v.packetBytes), chunks(v.data, v.serverChunks))
        let splitter = RawOpusPacketSplitter(packetBytes: v.packetBytes)
        let actual = split(splitter, chunks(v.data, v.misalignedChunks))

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(splitter.pendingBytes, 0)
    }

    func testResetDropsPartialPacket() throws {
        let v = try loadVector()
        let bytes = [UInt8](v.data)
        let splitter = RawOpusPacketSplitter(packetBytes: v.packetBytes)
        XCTAssertTrue(splitter.feed(Data(bytes[0..<50])).isEmpty)
        XCTAssertEqual(splitter.pendingBytes, 50)

        splitter.reset()

        XCTAssertEqual(splitter.pendingBytes, 0)
        let next = splitter.feed(Data(bytes[0..<80]))
        XCTAssertEqual(next, [Data(bytes[0..<80])])
    }

    /// 4 帧一包：与 Android 组装结果逐字节一致（Android 端已验证解码结果与逐包解码逐采样一致）
    func testAssembledPacketsMatchAndroidBytes() throws {
        let v = try loadVector()
        XCTAssertFalse(v.assembledPackets.isEmpty)
        let splitter = RawOpusPacketSplitter(packetBytes: v.packetBytes, framesPerPacket: v.assembledFrames)
        let assembled = split(splitter, chunks(v.sentence, v.sentenceChunks)) + splitter.flush()

        XCTAssertEqual(assembled, v.assembledPackets)
        XCTAssertEqual(splitter.pendingFrames, 0)
        XCTAssertLessThan(assembled.reduce(0) { $0 + $1.count }, v.sentence.count)
    }

    func testAssembledOutputDoesNotDependOnChunkBoundaries() throws {
        let v = try loadVector()
        let a = RawOpusPacketSplitter(packetBytes: v.packetBytes, framesPerPacket: 4)
        let b = RawOpusPacketSplitter(packetBytes: v.packetBytes, framesPerPacket: 4)
        let viaServer = split(a, chunks(v.data, v.serverChunks)) + a.flush()
        let viaMisaligned = split(b, chunks(v.data, v.misalignedChunks)) + b.flush()

        XCTAssertEqual(viaServer, viaMisaligned)
    }

    func testFlushEmitsRemainderAndResetDropsIt() throws {
        let v = try loadVector()
        let bytes = [UInt8](v.data)
        let splitter = RawOpusPacketSplitter(packetBytes: v.packetBytes, framesPerPacket: 4)
        XCTAssertEqual(splitter.feed(Data(bytes[0..<(6 * 80)])).count, 1)
        XCTAssertEqual(splitter.pendingFrames, 2)
        XCTAssertEqual(splitter.flush().count, 1)
        XCTAssertTrue(splitter.flush().isEmpty)

        _ = splitter.feed(Data(bytes[0..<(2 * 80)]))
        splitter.reset()
        XCTAssertEqual(splitter.pendingFrames, 0)
        XCTAssertTrue(splitter.flush().isEmpty)
    }
}
