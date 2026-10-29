import XCTest
@testable import XfCore

final class NoiseSuppressorTests: XCTestCase {

    /// 向量由 Android NoiseSuppressorTest 生成，两端对同一输入、同一分块方式的输出相差不超过 1
    func testMatchesSharedVectors() throws {
        // 本仓库里在 sdk/test-vectors；导出成独立 Swift Package 仓库后在仓库根目录的 test-vectors
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // XfCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ios（或独立仓库根目录）
        let candidates = [
            packageRoot.appendingPathComponent("test-vectors/noise-suppressor.json"),
            packageRoot.deletingLastPathComponent().appendingPathComponent("test-vectors/noise-suppressor.json"),
        ]
        let url = try XCTUnwrap(candidates.first { FileManager.default.fileExists(atPath: $0.path) },
                                "noise-suppressor.json not found")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let name = try XCTUnwrap(c["name"] as? String)
            let attenuation = try XCTUnwrap((c["maxAttenuationDb"] as? NSNumber)?.doubleValue)
            let chunks = try XCTUnwrap(c["chunks"] as? [Int])
            let input = try XCTUnwrap(c["input"] as? [Int]).map { Int16($0) }
            let expected = try XCTUnwrap(c["output"] as? [Int]).map { Int16($0) }
            let actual = processInChunks(NoiseSuppressor(maxAttenuationDb: attenuation), input, chunks)
            XCTAssertEqual(actual.count, expected.count, name)
            var mismatches = 0
            for i in 0..<expected.count where abs(Int(expected[i]) - Int(actual[i])) > 1 { mismatches += 1 }
            XCTAssertEqual(mismatches, 0, name)
        }
    }

    func testOutputHasSameLengthForAnyChunking() {
        let input = noise(count: 32_000, seed: 5)
        let whole = NoiseSuppressor().process(input)
        let chunked = processInChunks(NoiseSuppressor(), input, [1, 7, 160, 333, 640, 2000])
        XCTAssertEqual(whole.count, input.count)
        XCTAssertEqual(whole, chunked)
    }

    func testDataApiMatchesSampleApi() {
        let input = noise(count: 16_000, seed: 9)
        var bytes = Data()
        for s in input { withUnsafeBytes(of: s.littleEndian) { bytes.append(contentsOf: $0) } }
        let fromSamples = NoiseSuppressor().process(input)
        let fromBytes = [UInt8](NoiseSuppressor().process(bytes))
        for i in 0..<input.count {
            XCTAssertEqual(fromSamples[i], Int16(bitPattern: UInt16(fromBytes[i * 2]) | (UInt16(fromBytes[i * 2 + 1]) << 8)))
        }
    }

    func testZeroAttenuationOnlyDelays() {
        let input = noise(count: 16_000, seed: 2)
        let output = NoiseSuppressor(maxAttenuationDb: 0).process(input)
        let delay = NoiseSuppressor.latencySamples
        for i in 0..<delay { XCTAssertLessThanOrEqual(abs(Int(output[i])), 1) }
        for i in delay..<input.count { XCTAssertLessThanOrEqual(abs(Int(output[i]) - Int(input[i - delay])), 1) }
    }

    private func processInChunks(_ suppressor: NoiseSuppressor, _ input: [Int16], _ chunks: [Int]) -> [Int16] {
        var out = [Int16]()
        out.reserveCapacity(input.count)
        var pos = 0
        var c = 0
        while pos < input.count {
            let n = min(chunks[c % chunks.count], input.count - pos)
            c += 1
            out += suppressor.process(Array(input[pos..<pos + n]))
            pos += n
        }
        return out
    }

    private func noise(count: Int, seed: UInt64) -> [Int16] {
        var state = seed
        return (0..<count).map { _ in
            state = (state &* 1103515245 &+ 12345) & 0x7fffffff
            return Int16((Double(state) / 2147483648.0 - 0.5) * 2000)
        }
    }
}
