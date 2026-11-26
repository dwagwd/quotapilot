import XCTest
@testable import UsageCore

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)

/// With the master switch off nothing may reach any local backend, and the oMLX API key must never be read or sent.
final class LocalSwitchOffTests: XCTestCase {
    private func tempLog() -> (LocalLLMLog, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        return (LocalLLMLog(url: url), url)
    }

    func testNothingIsSentAndTheKeyIsNotReadWhileLocalModelsAreOff() throws {
        let server = try FakeServer { _, _ in FakeServer.Reply(slices: [Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}".utf8)]) }
        defer { server.shutdown() }
        let (log, url) = tempLog(); defer { try? FileManager.default.removeItem(at: url) }
        var keyReads = 0
        let service = LocalLLMService(log: log, omlxKey: { keyReads += 1; return "sk-test-key" }, llamaPorts: [server.port], omlxPort: server.port)
        var off = LocalLLMSettings(); off.enabled = false
        off.update(.ollama) { $0.upstreamPort = server.port }

        service.apply(off)
        XCTAssertTrue(service.pollOnce(now: 1).isEmpty)
        XCTAssertEqual(service.probe(settings: off)[.omlx], .off)
        XCTAssertEqual(service.probe(settings: off)[.llamacpp], .off)
        XCTAssertTrue(LocalEngineName.detectVersions(settings: off, backends: ["ollama", "llamacpp"]).isEmpty)
        // a settings value that was never switched on behaves the same
        XCTAssertEqual(service.probe(settings: LocalLLMSettings())[.omlx], .off)

        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(server.requests.count, 0, "no request of any kind")
        XCTAssertEqual(keyReads, 0, "the key was never read")
        XCTAssertFalse(server.requests.contains { $0.headers.keys.contains { $0.lowercased() == "authorization" } })
    }

    func testTheSameCallsDoReachTheServerOnceItIsSwitchedOn() throws {
        let server = try FakeServer { _, target in
            target.hasPrefix("/admin/api/usage") ? FakeServer.Reply(slices: [Data("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)])
                : FakeServer.Reply(slices: [Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)])
        }
        defer { server.shutdown() }
        let (log, url) = tempLog(); defer { try? FileManager.default.removeItem(at: url) }
        var keyReads = 0
        let service = LocalLLMService(log: log, omlxKey: { keyReads += 1; return "sk-test-key" }, llamaPorts: [server.port], omlxPort: server.port)
        var on = LocalLLMSettings(); on.enabled = true
        service.apply(on)
        _ = service.pollOnce(now: 1)
        XCTAssertGreaterThan(keyReads, 0)
        XCTAssertTrue(server.requests.contains { $0.headers.contains { $0.key.lowercased() == "authorization" } })
    }
}
#endif
