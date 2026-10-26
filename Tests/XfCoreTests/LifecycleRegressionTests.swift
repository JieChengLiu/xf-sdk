import Foundation
import XCTest
@testable import XfCore

final class LifecycleRegressionTests: XCTestCase {
    private func assertProtocolFailure(_ session: StreamSession, action: () -> Void) {
        let terminal = expectation(description: "one protocol failure")
        let observer = Task {
            do {
                for try await _ in session.events {}
                XCTFail("expected protocol failure")
            } catch {
                XCTAssertEqual((error as? XfError)?.kind, .protocol)
            }
            terminal.fulfill()
        }
        action()
        wait(for: [terminal], timeout: 2)
        observer.cancel()
        XCTAssertEqual(session.currentState, .closed)
    }

    func testPendingAudioOverflowFinishesWithErrorInsteadOfCrashing() {
        let network = URLSession(configuration: .ephemeral)
        defer { network.invalidateAndCancel() }
        let session = StreamSession(urlSession: network, url: URL(string: "ws://127.0.0.1:9")!,
                                    configJSON: ["command": "config"],
                                    auth: .device(DeviceCredentials(deviceId: "d") { "secret" }), clock: ServerClock())
        assertProtocolFailure(session) {
            session.sendAudio(Data(count: 2 * 1024 * 1024 + 1))
            session.sendAudio(Data([1]))
        }
        session.close()
    }

    func testPendingTextUsesUtf8ByteLimit() {
        let network = URLSession(configuration: .ephemeral)
        defer { network.invalidateAndCancel() }
        let session = StreamSession(urlSession: network, url: URL(string: "ws://127.0.0.1:9")!,
                                    configJSON: [:], auth: .device(DeviceCredentials(deviceId: "d") { "secret" }), clock: ServerClock())
        assertProtocolFailure(session) {
            session.sendCommand(["text": String(repeating: "汉", count: 700_000)])
        }
    }

    func testCloseDuringCredentialLookupDoesNotCreateLateSocket() {
        runBlockedConnect(timeout: 5, closeManually: true)
    }

    func testReadinessTimeoutWinsDuringCredentialLookup() {
        runBlockedConnect(timeout: 0.05, closeManually: false)
    }

    private func runBlockedConnect(timeout: TimeInterval, closeManually: Bool) {
        let network = URLSession(configuration: .ephemeral)
        defer { network.invalidateAndCancel() }
        let entered = expectation(description: "credential callback entered")
        let connected = expectation(description: "connect returned")
        let gate = DispatchSemaphore(value: 0)
        let count = Counter()
        let credentials = DeviceCredentials(deviceId: "d") {
            entered.fulfill()
            _ = gate.wait(timeout: .now() + 3)
            return "secret"
        }
        let session = StreamSession(urlSession: network, url: URL(string: "ws://127.0.0.1:9")!,
                                    configJSON: ["command": "config"], auth: .device(credentials), clock: ServerClock(),
                                    readyTimeout: timeout, makeWebSocketTask: { request in
                                        count.increment()
                                        return network.webSocketTask(with: request)
                                    })
        let begin = {
            DispatchQueue.global().async { session.connect(); connected.fulfill() }
            self.wait(for: [entered], timeout: 1)
        }
        if closeManually {
            begin()
            session.close()
        } else {
            assertProtocolFailure(session, action: begin)
        }
        gate.signal()
        wait(for: [connected], timeout: 2)
        XCTAssertEqual(count.value, 0, "a closed session must never create a late WebSocket")
        XCTAssertEqual(session.currentState, .closed)
        session.close()
    }

    private final class Counter {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
}
