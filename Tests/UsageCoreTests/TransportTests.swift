import XCTest
import Foundation
import UsageTransport
@testable import UsageCore

// These tests start a fake Codex app server from a shell script and check process ids with POSIX kill,
// so they run on macOS and Linux only. Windows builds the transport and runs the other suites.
#if !os(Windows)
final class TransportTests: XCTestCase {
    private var directories: [URL] = []
    override func tearDown() {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories = []
        super.tearDown()
    }
    private func fixture(mode: String) throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usage-transport-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        directories.append(dir)
        let executable = dir.appendingPathComponent("fake-codex")
        let script = """
        #!/usr/bin/python3
        import json,sys,os
        from pathlib import Path
        root=Path(__file__).parent
        (root/'pid').write_text(str(os.getpid()))
        for line in sys.stdin:
            request=json.loads(line)
            method=request.get('method')
            with (root/'requests').open('a') as log: log.write(method+'\\n')
            if method=='initialize': result={}
            elif method=='initialized': continue
            elif method=='account/read': result={'account':{'type':'chatgpt','email':'fixture@example.invalid'}}
            elif method=='account/rateLimits/read':
                if '\(mode)'=='hang': continue
                if '\(mode)'=='exit': sys.exit(1)
                if '\(mode)'=='error':
                    print(json.dumps({'id':request['id'],'error':{'code':-1,'message':'test error'}}),flush=True)
                    continue
                result={'accountId':'fixture-account','rateLimitsByLimitId':{'codex':{'primary':{'usedPercent':25,'windowDurationMins':10080,'resetsAt':2000000000}}}}
            elif method=='account/usage/read':
                if '\(mode)'=='tokens-hang': continue
                if '\(mode)'=='tokens-error':
                    print(json.dumps({'id':request['id'],'error':{'code':-32601,'message':'Unsupported'}}),flush=True)
                    continue
                result={'summary':{'lifetimeTokens':100000}}
            else: sys.exit(2)
            print(json.dumps({'id':request['id'],'result':result}),flush=True)
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (executable, dir)
    }
    func testReadOnlyProtocolAndCleanShutdown() throws {
        let (executable, dir) = try fixture(mode: "success")
        let client = UsageClient(executable: executable.path, requestTimeout: 3)
        let received = expectation(description: "quota")
        let tokens = expectation(description: "tokens")
        client.onTokens = { total, _ in XCTAssertEqual(total, 100000); tokens.fulfill() }
        client.onResult = { response, account in
            XCTAssertEqual(response.windows().first?.window.usedPercent, 25)
            XCTAssertEqual(account.count, 64)
            XCTAssertNotNil(client.diagnostics.lastAttemptAt)
            XCTAssertNotNil(client.diagnostics.lastQuotaSuccessAt)
            received.fulfill()
        }
        client.onFailure = { XCTFail($0) }
        client.refresh()
        wait(for: [received, tokens], timeout: 5)
        XCTAssertNotNil(client.diagnostics.lastTokenSuccessAt)
        XCTAssertEqual(client.diagnostics.lastTokenAttemptAccountKey, client.diagnostics.lastTokenSuccessAccountKey)
        XCTAssertNotNil(client.diagnostics.lastTokenSuccessAccountKey)
        XCTAssertNil(client.diagnostics.lastTokenErrorCode)
        let pid = Int32(try String(contentsOf: dir.appendingPathComponent("pid")))!
        client.stop()
        XCTAssertEqual(kill(pid, 0), -1)
        let methods = try String(contentsOf: dir.appendingPathComponent("requests"))
        XCTAssertTrue(methods.contains("account/rateLimits/read"))
        XCTAssertTrue(methods.contains("account/usage/read"))
        XCTAssertFalse(methods.contains("turn/start"))
        XCTAssertFalse(methods.contains("thread/start"))
    }
    func testErrorTimeoutAndUnexpectedExit() throws {
        for mode in ["error", "hang", "exit"] {
            let (executable, _) = try fixture(mode: mode)
            let client = UsageClient(executable: executable.path, requestTimeout: 0.5, retryBase: 10)
            let failed = expectation(description: mode)
            client.onResult = { _, _ in XCTFail("Unexpected success") }
            client.onFailure = { _ in failed.fulfill() }
            client.refresh()
            wait(for: [failed], timeout: 3)
            client.stop()
        }
    }
    func testSuspendAndResumeStartsFreshConnection() throws {
        let (executable, dir) = try fixture(mode: "success")
        let client = UsageClient(executable: executable.path, requestTimeout: 3)
        let first = expectation(description: "before sleep")
        client.onResult = { _, _ in first.fulfill() }
        client.refresh(); wait(for: [first], timeout: 5)
        let oldPID = Int32(try String(contentsOf: dir.appendingPathComponent("pid")))!
        client.suspend()
        let second = expectation(description: "after wake")
        client.onResult = { _, _ in second.fulfill() }
        client.resume(); wait(for: [second], timeout: 5)
        let newPID = Int32(try String(contentsOf: dir.appendingPathComponent("pid")))!
        XCTAssertNotEqual(oldPID, newPID)
        client.stop()
        XCTAssertEqual(kill(newPID, 0), -1)
    }
    func testMissingTokenEndpointAndTimeoutPreserveFreshQuota() throws {
        for mode in ["tokens-error", "tokens-hang"] {
            let (executable, _) = try fixture(mode: mode)
            // Real-time timer in the client: 4 s keeps a cold Python start on a slow CI disk from timing out the handshake, and the
            // expectation below allows the handshake, the quota call and the hung token call (one timeout) with plenty of margin.
            let client = UsageClient(executable: executable.path, requestTimeout: 4)
            let quota = expectation(description: "quota preserved")
            let tokens = expectation(description: "tokens unavailable")
            client.onResult = { response, _ in
                XCTAssertEqual(response.windows().first?.window.usedPercent, 25); quota.fulfill()
            }
            client.onTokens = { value, _ in XCTAssertNil(value); tokens.fulfill() }
            client.onFailure = { XCTFail("Optional tokens must not invalidate quota: " + $0) }
            client.refresh(); wait(for: [quota, tokens], timeout: 40)
            XCTAssertNotNil(client.diagnostics.lastQuotaSuccessAt)
            XCTAssertNil(client.diagnostics.lastTokenSuccessAt)
            XCTAssertNotNil(client.diagnostics.lastTokenErrorCode)
            XCTAssertEqual(client.diagnostics.consecutiveTokenFailures, 1)
            XCTAssertNotNil(client.diagnostics.lastTokenAttemptAccountKey)
            XCTAssertNil(client.diagnostics.lastTokenSuccessAccountKey)
            client.stop()
        }
    }


    func testExecutableCandidatesIncludeChatGPTCodexCLIBundle() {
        let candidates = UsageClient.executableCandidates(environment: ["PATH": "/bin"], home: "/Users/u")
        let bundled = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        XCTAssertTrue(candidates.contains(bundled))
        XCTAssertLessThan(candidates.firstIndex(of: bundled)!, candidates.firstIndex(of: "/bin/codex")!)
        XCTAssertEqual(UsageClient.executableCandidates(environment: ["CODEX_USAGE_CODEX_PATH": "/x/codex"], home: "/h").first, "/x/codex")
    }
    func testNewestFirstComparesVersionsNumerically() {
        XCTAssertEqual(UsageClient.newestFirst(["v9.0.0", "v20.11.1", "v20.9.0", "v18.20.4", "v20.11.10"]),
                       ["v20.11.10", "v20.11.1", "v20.9.0", "v18.20.4", "v9.0.0"])
        XCTAssertEqual(UsageClient.newestFirst(["20.1", "v20.1.0.1", "v20"]), ["v20.1.0.1", "20.1", "v20"])
        XCTAssertEqual(UsageClient.newestFirst([]), [])
    }
    func testNodeVersionManagerCandidatesComeAfterTheUsualOnesNewestFirst() {
        let home = "/Users/u"
        let candidates = UsageClient.executableCandidates(environment: ["PATH": "/bin"], home: home) { directory in
            directory.hasSuffix("/.nvm/versions/node") ? ["v18.20.4", "v22.1.0", "v9.0.0"]
                : directory == home + "/.fnm/node-versions" ? ["v20.0.0", "v20.10.0"]
                : directory == home + "/Library/Application Support/fnm/node-versions" ? ["v22.2.0"] : []
        }
        func index(_ path: String) -> Int { candidates.firstIndex(of: path)! }
        let nvm = { (v: String) in home + "/.nvm/versions/node/" + v + "/bin/codex" }
        XCTAssertLessThan(index(home + "/.npm-global/bin/codex"), index(home + "/.volta/bin/codex"))
        XCTAssertLessThan(index(nvm("v22.1.0")), index(nvm("v18.20.4")))
        XCTAssertLessThan(index(nvm("v18.20.4")), index(nvm("v9.0.0")))
        XCTAssertLessThan(index(home + "/.fnm/node-versions/v20.10.0/installation/bin/codex"), index(home + "/.fnm/node-versions/v20.0.0/installation/bin/codex"))
        XCTAssertTrue(candidates.contains(home + "/Library/Application Support/fnm/node-versions/v22.2.0/installation/bin/codex"))
        for path in ["/Library/Application Support/fnm/aliases/default/bin", "/.bun/bin", "/Library/pnpm", "/.local/share/pnpm", "/.local/share/mise/shims", "/.asdf/shims", "/.local/share/fnm/aliases/default/bin"] {
            XCTAssertTrue(candidates.contains(home + path + "/codex"), path)
        }
    }
    func testChildPathPutsTheExecutableFolderFirst() {
        XCTAssertEqual(UsageClient.childPath(executable: "/h/.nvm/versions/node/v22/bin/codex", inheritedPath: "/usr/bin:/bin"), "/h/.nvm/versions/node/v22/bin:/usr/bin:/bin")
        XCTAssertEqual(UsageClient.childPath(executable: "/h/bin/codex", inheritedPath: nil), "/h/bin")
        XCTAssertEqual(UsageClient.childPath(executable: "/h/bin/codex", inheritedPath: ""), "/h/bin")
    }
    func testPortableSHA256MatchesKnownVectors() {
        XCTAssertEqual(Portable.sha256Hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(Portable.sha256Hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(Portable.sha256Hex(String(repeating: "a", count: 1000)).count, 64)
    }
}
#endif

final class PortableAtomicReplaceTests: XCTestCase {
    func testAtomicReplaceOverwritesExistingFileAndKeepsPrivatePermissions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("replace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("target.jsonl")
        let temp = dir.appendingPathComponent("target.jsonl.tmp")
        try Data("old".utf8).write(to: target)
        XCTAssertTrue(FileManager.default.createFile(atPath: temp.path, contents: Data("new".utf8), attributes: [.posixPermissions: 0o600]))
        XCTAssertTrue(Portable.atomicReplace(target, with: temp))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
        #if !os(Windows)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
        #endif
    }

    func testAtomicReplaceCreatesMissingDestinationAndFailsWithoutSource() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("replace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("fresh")
        let temp = dir.appendingPathComponent("fresh.tmp")
        try Data("x".utf8).write(to: temp)
        XCTAssertTrue(Portable.atomicReplace(target, with: temp))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "x")
        XCTAssertFalse(Portable.atomicReplace(target, with: dir.appendingPathComponent("missing")))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "x")
    }
}
