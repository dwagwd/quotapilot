import Foundation

/// Which requests are model calls worth counting (everything else, such as `/api/tags` or `/v1/models`, is ignored).
public enum LocalLLMPaths {
    public static func isInference(method: String, target: String) -> Bool {
        guard method.uppercased() == "POST" else { return false }
        let path = (target.split(separator: "?").first.map(String.init) ?? target).lowercased()
        let suffixes = ["/chat/completions", "/completions", "/completion", "/embeddings", "/embedding", "/embed", "/api/chat", "/api/generate",
                        "/messages", "/responses", "/api/v1/chat", "/rerank", "/infill", "/audio/transcriptions"]
        return suffixes.contains { path.hasSuffix($0) }
    }
}

/// Reads copies of the bytes of one proxied connection and turns each model call into at most one event. It follows HTTP framing
/// only to find response bodies; request bodies (the prompts) are skipped without being kept. It cannot affect forwarding.
final class MeterTap {
    private struct Exchange { let method: String; let target: String; let start: Double; var sentAt: Double? }
    private enum Mode { case sse, ndjson, json, skip, compressed }

    private let backend: String
    private let emit: (LocalLLMEvent) -> Void
    private let lock = NSLock()
    private var queue: [Exchange] = []
    private let requestParser = HTTPStreamParser(role: .request)
    private let responseParser = HTTPStreamParser(role: .response)

    // Response being read (touched only by the response thread).
    private var current: Exchange?
    private var status = 0
    private var mode = Mode.skip
    private var lines = LocalLineScanner(kind: .sse)
    private var json = Data()
    private var jsonTooLarge = false
    private var firstBodyAt: Double?

    private static let maxJSON = 8 * 1_048_576
    private static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    init(backend: String, emit: @escaping (LocalLLMEvent) -> Void) {
        self.backend = backend; self.emit = emit
        requestParser.onHead = { [weak self] head in
            guard let self else { return }
            self.lock.lock(); self.queue.append(Exchange(method: head.method, target: head.target, start: Self.now(), sentAt: nil)); self.lock.unlock()
        }
        requestParser.onMessageEnd = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if let index = self.queue.lastIndex(where: { $0.sentAt == nil }) { self.queue[index].sentAt = Self.now() }
            self.lock.unlock()
        }
        responseParser.nextResponseHasNoBody = { [weak self] in
            guard let self else { return false }
            self.lock.lock(); defer { self.lock.unlock() }
            return self.queue.first?.method.uppercased() == "HEAD"
        }
        responseParser.onHead = { [weak self] head in self?.responseHead(head) }
        responseParser.onBody = { [weak self] data in self?.responseBody(data) }
        responseParser.onMessageEnd = { [weak self] in self?.finishExchange(interrupted: false) }
    }

    func requestBytes(_ data: Data) { requestParser.feed(data) }
    func responseBytes(_ data: Data) { responseParser.feed(data) }
    /// The upstream closed: a body that runs until close ends here; an unfinished one is booked as interrupted.
    func responseClosed() {
        responseParser.finish()
        if current != nil { finishExchange(interrupted: true) }
    }

    private func responseHead(_ head: HTTPStreamParser.Head) {
        lock.lock(); current = queue.isEmpty ? nil : queue.removeFirst(); lock.unlock()
        status = head.status; json = Data(); jsonTooLarge = false; firstBodyAt = nil
        let type = head.headers["content-type"]?.lowercased() ?? ""
        let encoding = head.headers["content-encoding"]?.lowercased() ?? "identity"
        if encoding != "identity" && !encoding.isEmpty { mode = .compressed }
        else if type.contains("text/event-stream") { mode = .sse; lines = LocalLineScanner(kind: .sse) }
        else if type.contains("ndjson") || type.contains("jsonl") || type.contains("x-json-stream") { mode = .ndjson; lines = LocalLineScanner(kind: .ndjson) }
        else if type.contains("json") { mode = .json }
        else { mode = .skip }
    }

    private func responseBody(_ data: Data) {
        guard current != nil, !data.isEmpty else { return }
        if firstBodyAt == nil { firstBodyAt = Self.now() }
        switch mode {
        case .sse, .ndjson: lines.feed(data)
        case .json:
            if jsonTooLarge { return }
            json.append(data)
            if json.count > Self.maxJSON { json = Data(); jsonTooLarge = true }
        case .skip, .compressed: break
        }
    }

    private func finishExchange(interrupted: Bool) {
        guard let exchange = current else { return }
        current = nil
        defer { json = Data() }
        guard LocalLLMPaths.isInference(method: exchange.method, target: exchange.target), (200..<300).contains(status) || interrupted else { return }
        var fields = LocalUsageFields()
        switch mode {
        case .sse, .ndjson: lines.finish(); fields = lines.accumulator.fields
        case .json: if !jsonTooLarge { fields = LocalJSONBody.fields(json) }
        case .skip, .compressed: break
        }
        if fields.isLoadOnly { return }
        let end = Self.now()
        let started = exchange.sentAt ?? exchange.start
        let duration = max(0, end - started)
        let streaming = mode == .sse || mode == .ndjson
        var event = LocalLLMEvent(id: UUID().uuidString, t: Date().timeIntervalSince1970, backend: backend, via: "proxy",
                                  model: fields.model, requests: 1, seconds: duration)
        guard fields.hasCounts else {
            event.unmetered = 1
            emit(event); return
        }
        event.prompt = fields.prompt ?? 0; event.cached = min(fields.cached, event.prompt)
        event.completion = fields.completion ?? 0; event.reasoning = min(fields.reasoning, event.completion)
        if let total = fields.totalSeconds { event.seconds = total }
        if fields.engineTimings {
            event.promptSeconds = fields.promptSeconds; event.genSeconds = fields.genSeconds; event.timing = "engine"
        } else if streaming, !interrupted, event.completion > 0, let first = firstBodyAt {
            // Derived from what the proxy measured: time to the first body byte as prompt time, the rest as generation.
            let firstDelay = max(0, first - started), rest = max(0, end - first)
            if rest >= 0.05 {
                event.promptSeconds = firstDelay > 0 ? firstDelay : nil; event.genSeconds = rest; event.timing = "proxy"
            }
        }
        emit(event)
    }
}

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)

/// A relay on 127.0.0.1 that copies every byte between a client and one local model server unchanged and meters the responses
/// on the side. See docs/local-llm.md, "Metering proxy".
public final class LocalMeteringProxy {
    public let backend: LocalLLMBackend
    public let upstreamHost: String
    public let upstreamPort: Int
    public private(set) var port: Int
    private let onEvent: (LocalLLMEvent) -> Void
    private var listener: Int32 = -1
    private let lock = NSLock()
    private var stopped = true
    private var connections: Set<Int32> = []
    private static let maxConnections = 256

    /// - Parameter listenPort: 0 picks a free port (tests); otherwise 1024...65535.
    public init(backend: LocalLLMBackend, listenPort: Int, upstreamHost: String = "127.0.0.1", upstreamPort: Int, onEvent: @escaping (LocalLLMEvent) -> Void) {
        self.backend = backend; self.port = listenPort; self.upstreamHost = upstreamHost; self.upstreamPort = upstreamPort; self.onEvent = onEvent
    }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return !stopped }

    public func start() throws {
        guard port == 0 || (1024...65535).contains(port) else { throw LocalSockets.SocketError(description: "port \(port) is not allowed") }
        let fd = try LocalSockets.listenLoopback(port: port)
        lock.lock(); listener = fd; stopped = false; lock.unlock()
        port = LocalSockets.boundPort(fd)
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
    }

    public func stop() {
        lock.lock()
        stopped = true
        let open = connections
        lock.unlock()
        for fd in open { LocalSockets.shutdownBoth(fd) }
    }

    private var shouldStop: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private func acceptLoop(_ fd: Int32) {
        while !shouldStop {
            guard let client = LocalSockets.acceptConnection(fd, waitMilliseconds: 250) else { continue }
            lock.lock()
            let full = connections.count >= Self.maxConnections
            if !full { connections.insert(client) }
            lock.unlock()
            if full { LocalSockets.closeSocket(client); continue }
            Thread.detachNewThread { [weak self] in self?.serve(client) }
        }
        LocalSockets.closeSocket(fd)
    }

    private func serve(_ client: Int32) {
        defer {
            lock.lock(); connections.remove(client); lock.unlock()
            LocalSockets.closeSocket(client)
        }
        guard let upstream = LocalSockets.connect(host: upstreamHost, port: upstreamPort, timeoutMilliseconds: 3000) else {
            let reply = Array("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            _ = reply.withUnsafeBytes { LocalSockets.sendAll(client, $0) }
            return
        }
        defer { LocalSockets.closeSocket(upstream) }
        let tap = MeterTap(backend: backend.rawValue, emit: onEvent)
        let finished = DispatchSemaphore(value: 0)
        // upstream -> client on its own thread; client -> upstream on this one.
        Thread.detachNewThread {
            Self.pump(from: upstream, to: client) { tap.responseBytes($0) }
            tap.responseClosed()
            LocalSockets.shutdownBoth(client)   // nothing more will come back: let the other direction end
            finished.signal()
        }
        Self.pump(from: client, to: upstream) { tap.requestBytes($0) }
        LocalSockets.shutdownWrite(upstream)
        finished.wait()
    }

    /// Copies bytes from `source` to `destination` as they arrive, then hands the same bytes to `observe`. Forwarding comes first so
    /// metering never delays the client.
    private static func pump(from source: Int32, to destination: Int32, observe: (Data) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = LocalSockets.receive(source, into: &buffer)
            if count <= 0 { break }
            let ok = buffer.withUnsafeBytes { LocalSockets.sendAll(destination, UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
            observe(Data(buffer[0..<count]))
            if !ok { break }
        }
        LocalSockets.shutdownWrite(destination)
    }
}

#else

public final class LocalMeteringProxy {
    public let backend: LocalLLMBackend
    public private(set) var port: Int
    public init(backend: LocalLLMBackend, listenPort: Int, upstreamHost: String = "127.0.0.1", upstreamPort: Int, onEvent: @escaping (LocalLLMEvent) -> Void) {
        self.backend = backend; self.port = listenPort
    }
    public var isRunning: Bool { false }
    public func start() throws { throw NSError(domain: "QuotaPilot", code: 1, userInfo: [NSLocalizedDescriptionKey: "The metering proxy is not available on this platform"]) }
    public func stop() {}
}

#endif
