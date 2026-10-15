import XCTest
@testable import UsageCore

final class AgentTokenLedgerTests: XCTestCase {
    private func codexLine(_ time: String, input: Int, cached: Int, output: Int, reasoning: Int, cumulative: Int) -> String {
        #"{"timestamp":"\#(time)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\#(cumulative)},"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"cache_write_input_tokens":0,"output_tokens":\#(output),"reasoning_output_tokens":\#(reasoning),"total_tokens":\#(input + output)}},"rate_limits":{}}}"#
    }
    private func claudeLine(_ time: String, id: String, input: Int, read: Int, write: Int, output: Int) -> String {
        #"{"type":"assistant","timestamp":"\#(time)","requestId":"req_\#(id)","message":{"id":"msg_\#(id)","content":[{"type":"text","text":"secret"}],"usage":{"input_tokens":\#(input),"cache_read_input_tokens":\#(read),"cache_creation_input_tokens":\#(write),"output_tokens":\#(output)}}}"#
    }

    func testCodexEventSplitsCachedInputAndReasoning() throws {
        let event = try XCTUnwrap(AgentLogParser.codexEvent(codexLine("2026-10-15T03:00:00.000Z", input: 1000, cached: 600, output: 200, reasoning: 50, cumulative: 1200)))
        XCTAssertEqual(event.provider, "codex")
        XCTAssertEqual(event.usage, TokenBreakdown(input: 400, cacheRead: 600, cacheWrite: 0, output: 200, reasoning: 50))
        XCTAssertEqual(event.usage.total, 1200)
        XCTAssertNil(AgentLogParser.codexEvent(#"{"type":"response_item","payload":{"type":"message","content":"token_count"}}"#))
        XCTAssertNil(AgentLogParser.codexEvent("not json token_count"))
    }

    func testClaudeEventReadsCacheFieldsAndIgnoresUserLines() throws {
        let event = try XCTUnwrap(AgentLogParser.claudeEvent(claudeLine("2026-10-15T03:00:00Z", id: "a", input: 5, read: 900, write: 100, output: 40)))
        XCTAssertEqual(event.usage, TokenBreakdown(input: 5, cacheRead: 900, cacheWrite: 100, output: 40))
        XCTAssertEqual(event.dedupeKey, "claude|msg_a|req_a")
        XCTAssertNil(AgentLogParser.claudeEvent(#"{"type":"user","timestamp":"2026-10-15T03:00:00Z","message":{"usage":{"input_tokens":5}}}"#))
    }

    func testLedgerDeduplicatesAndSummarizesWindow() {
        var ledger = AgentTokenLedger(retention: 3600)
        let a = AgentTokenEvent(provider: "codex", timestamp: 1_000, usage: TokenBreakdown(input: 10, output: 5), dedupeKey: "a")
        XCTAssertTrue(ledger.add(a))
        XCTAssertFalse(ledger.add(a))
        ledger.add(AgentTokenEvent(provider: "claude", timestamp: 1_100, usage: TokenBreakdown(cacheRead: 100), dedupeKey: "b"))
        ledger.add(AgentTokenEvent(provider: "claude", timestamp: 4_000, usage: TokenBreakdown(output: 7), dedupeKey: "c"))
        XCTAssertEqual(ledger.total(since: 900, now: 1_200).total, 115)
        XCTAssertEqual(ledger.summary(since: 3_900, now: 4_100)["claude"]?.output, 7)
        ledger.prune(now: 5_000)
        XCTAssertNil(ledger.summary(since: 0, now: 5_000)["codex"])
        XCTAssertTrue(ledger.add(a), "pruned keys may be seen again only after leaving retention")
    }

    func testScannerReadsBackwardThenIncrementallyAndSkipsPartialLines() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let day = root.appendingPathComponent("2026/10/15", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = day.appendingPathComponent("rollout.jsonl")
        let filler = String(repeating: "x", count: 200)
        var lines: [String] = []
        for i in 0..<2_000 {
            lines.append(#"{"timestamp":"2026-10-15T00:00:00Z","type":"response_item","payload":{"text":"\#(filler)"}}"#)
            if i % 100 == 0 {
                let minute = String(format: "%02d", i / 100)
                lines.append(codexLine("2026-10-15T01:\(minute):00.000Z", input: 100, cached: 0, output: 10, reasoning: 0, cumulative: i))
            }
        }
        try (lines.joined(separator: "\n") + "\n" + codexLine("2026-10-15T02:00:00.000Z", input: 1, cached: 0, output: 1, reasoning: 0, cumulative: 9).dropLast(5))
            .write(to: file, atomically: true, encoding: .utf8)
        let scanner = AgentLogScanner(sources: [.init(provider: "codex", root: root, parse: AgentLogParser.codexEvent)])
        let windowStart = try XCTUnwrap(AgentLogParser.timestamp("2026-10-15T01:10:00Z"))
        let first = scanner.scan(windowStart: windowStart)
        XCTAssertEqual(first.count, 10, "events 01:10 … 01:19, partial last line excluded")

        let partial = codexLine("2026-10-15T02:00:00.000Z", input: 1, cached: 0, output: 1, reasoning: 0, cumulative: 9)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((String(partial.suffix(5)) + "\n").utf8))
        try handle.close()
        let second = scanner.scan(windowStart: windowStart)
        XCTAssertEqual(second.count, 1, "the completed line is read exactly once")
        let third = scanner.scan(windowStart: windowStart)
        XCTAssertTrue(third.isEmpty)
    }

    func testScannerAppendsNewCompleteLines() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        try (claudeLine("2026-10-15T03:00:00Z", id: "1", input: 1, read: 2, write: 3, output: 4) + "\n").write(to: file, atomically: true, encoding: .utf8)
        let scanner = AgentLogScanner(sources: [.init(provider: "claude", root: root, parse: AgentLogParser.claudeEvent)])
        XCTAssertEqual(scanner.scan(windowStart: 0).count, 1)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((claudeLine("2026-10-15T03:01:00Z", id: "2", input: 1, read: 0, write: 0, output: 1) + "\n").utf8))
        try handle.close()
        let added = scanner.scan(windowStart: 0)
        XCTAssertEqual(added.map(\.dedupeKey), ["claude|msg_2|req_2"])
        XCTAssertTrue(scanner.scan(windowStart: 0).isEmpty)
    }

    func testClaudeCodeUsageIsAttributedToTheAnsweringModelFamily() {
        XCTAssertEqual(AgentLogParser.providerForModel("claude-opus-5-5"), "claude")
        XCTAssertEqual(AgentLogParser.providerForModel("deepseek-chat"), "deepseek")
        XCTAssertEqual(AgentLogParser.providerForModel("kimi-k2-turbo"), "kimi")
        XCTAssertEqual(AgentLogParser.providerForModel("<synthetic>"), "claude")
        XCTAssertEqual(AgentLogParser.providerForModel(nil), "claude")
        let line = #"{"type":"assistant","timestamp":"2026-10-15T03:00:00Z","message":{"id":"m","model":"deepseek-reasoner","usage":{"input_tokens":3,"output_tokens":4}}}"#
        XCTAssertEqual(AgentLogParser.claudeEvent(line)?.provider, "deepseek")
    }
}
