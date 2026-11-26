import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// Minimal HTTP/1.1 pieces for the local-model meter: an incremental message parser (framing only), BSD sockets
// and a tiny GET client with short timeouts. Sockets exist on macOS and Linux; on Windows the meter is unavailable.

/// Follows HTTP/1.1 message boundaries in one direction of a connection. It never changes or forwards bytes; it only reports
/// heads, decoded body bytes (chunked framing removed) and message ends. On anything it cannot follow it gives up
/// (`failed`) and stays silent, which never affects the connection it watches.
public final class HTTPStreamParser {
    public enum Role { case request, response }
    public struct Head {
        public let startLine: String
        /// Lowercased names; repeated headers joined with ", ".
        public let headers: [String: String]
        public var method: String { String(startLine.split(separator: " ").first ?? "") }
        public var target: String { startLine.split(separator: " ").dropFirst().first.map(String.init) ?? "" }
        public var status: Int { startLine.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0 }
    }
    private enum State { case head, fixed(Int), chunkSize, chunkData(Int), chunkEnd, trailers, untilClose }

    public let role: Role
    public var onHead: ((Head) -> Void)?
    public var onBody: ((Data) -> Void)?
    public var onMessageEnd: (() -> Void)?
    /// Responses to HEAD (and 204/304) have no body; the owner says so for HEAD.
    public var nextResponseHasNoBody: () -> Bool = { false }
    public private(set) var failed = false
    private var state = State.head
    private var pending = Data()
    private static let maxHead = 64 * 1024

    public init(role: Role) { self.role = role }

    public func feed(_ data: Data) {
        guard !failed else { return }
        pending.append(data)
        process()
    }

    /// The connection closed: a response that runs until close ends here.
    public func finish() {
        guard !failed else { return }
        if case .untilClose = state { state = .head; onMessageEnd?() }
    }

    private func fail() { failed = true; pending = Data(); state = .head }

    private func process() {
        while !failed {
            switch state {
            case .head:
                guard let end = Self.find(pending, [13, 10, 13, 10]) else {
                    if pending.count > Self.maxHead { fail() }
                    return
                }
                let headData = pending.prefix(end)
                pending.removeSubrange(pending.startIndex..<pending.startIndex + end + 4)
                guard let head = Self.parseHead(headData),
                      role == .response ? head.startLine.hasPrefix("HTTP/") : head.startLine.contains(" HTTP/") else { fail(); return }
                beginMessage(head)
            case .fixed(let remaining):
                if remaining == 0 { state = .head; onMessageEnd?(); continue }
                guard !pending.isEmpty else { return }
                let take = min(remaining, pending.count)
                onBody?(pending.prefix(take))
                pending.removeSubrange(pending.startIndex..<pending.startIndex + take)
                state = take == remaining ? .fixed(0) : .fixed(remaining - take)
            case .chunkSize:
                guard let newline = pending.firstIndex(of: 10) else {
                    if pending.count > 1024 { fail() }
                    return
                }
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...newline)
                let digits = line.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
                guard let size = Int(digits, radix: 16), size >= 0 else { fail(); return }
                state = size == 0 ? .trailers : .chunkData(size)
            case .chunkData(let remaining):
                guard !pending.isEmpty else { return }
                let take = min(remaining, pending.count)
                onBody?(pending.prefix(take))
                pending.removeSubrange(pending.startIndex..<pending.startIndex + take)
                state = take == remaining ? .chunkEnd : .chunkData(remaining - take)
            case .chunkEnd:
                guard let newline = pending.firstIndex(of: 10) else { return }
                pending.removeSubrange(pending.startIndex...newline)
                state = .chunkSize
            case .trailers:
                guard let newline = pending.firstIndex(of: 10) else {
                    if pending.count > Self.maxHead { fail() }
                    return
                }
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                if line.isEmpty || line == Data([13]) { state = .head; onMessageEnd?() }
            case .untilClose:
                guard !pending.isEmpty else { return }
                onBody?(pending)
                pending = Data()
                return
            }
        }
    }

    private func beginMessage(_ head: Head) {
        let chunked = head.headers["transfer-encoding"]?.lowercased().contains("chunked") == true
        let length = head.headers["content-length"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        switch role {
        case .request:
            onHead?(head)
            if chunked { state = .chunkSize } else if let length, length > 0 { state = .fixed(length) } else { onMessageEnd?(); state = .head }
        case .response:
            let status = head.status
            if status == 101 { onHead?(head); fail(); return }          // protocol switch: not HTTP any more
            if (100..<200).contains(status) { return }                   // informational, a final response follows
            // Decided before the head is reported: the owner may take the exchange off its queue when it sees the head,
            // and the question is about the request this response answers (HEAD has no body whatever Content-Length says).
            let noBody = status == 204 || status == 304 || nextResponseHasNoBody()
            onHead?(head)
            if noBody { onMessageEnd?(); state = .head; return }
            if chunked { state = .chunkSize }
            else if let length { state = length > 0 ? .fixed(length) : .head; if length == 0 { onMessageEnd?() } }
            else { state = .untilClose }
        }
    }

    static func parseHead(_ data: Data) -> Head? {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let start = lines.removeFirst()
        guard start.contains(" ") else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { $0 + ", " + value } ?? value
        }
        return Head(startLine: start, headers: headers)
    }

    private static func find(_ data: Data, _ needle: [UInt8]) -> Int? {
        guard data.count >= needle.count else { return nil }
        let base = data.startIndex
        var index = 0
        let last = data.count - needle.count
        while index <= last {
            if data[base + index] == needle[0] {
                var match = true
                for offset in 1..<needle.count where data[base + index + offset] != needle[offset] { match = false; break }
                if match { return index }
            }
            index += 1
        }
        return nil
    }
}

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)

// File-scope aliases: inside `LocalSockets` the names `connect` and `close` would resolve to its own methods.
@inline(__always) private func sysConnect(_ fd: Int32, _ address: UnsafePointer<sockaddr>!, _ length: socklen_t) -> Int32 { connect(fd, address, length) }
@inline(__always) private func sysClose(_ fd: Int32) -> Int32 { close(fd) }

/// Thin wrappers over BSD sockets (IPv4 loopback listener, any-address client).
public enum LocalSockets {
    public static let isSupported = true
    private static var streamType: Int32 {
        #if canImport(Glibc)
        return Int32(SOCK_STREAM.rawValue)
        #else
        return SOCK_STREAM
        #endif
    }
    #if canImport(Darwin)
    private static let noSignal: Int32 = 0
    #else
    private static let noSignal: Int32 = Int32(MSG_NOSIGNAL)
    #endif

    public static func ignoreBrokenPipe() { signal(SIGPIPE, SIG_IGN) }

    public struct SocketError: Error, CustomStringConvertible {
        public let description: String
    }

    /// Listening socket on 127.0.0.1 only. Port 0 picks a free one (tests).
    public static func listenLoopback(port: Int) throws -> Int32 {
        ignoreBrokenPipe()
        let fd = socket(AF_INET, streamType, 0)
        guard fd >= 0 else { throw SocketError(description: "socket: \(String(cString: strerror(errno)))") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 64) == 0 else {
            let message = String(cString: strerror(errno))
            _ = sysClose(fd)
            throw SocketError(description: "127.0.0.1:\(port): \(message)")
        }
        return fd
    }

    public static func boundPort(_ fd: Int32) -> Int {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return result == 0 ? Int(UInt16(bigEndian: address.sin_port)) : 0
    }

    /// Waits up to `milliseconds` for a connection; nil on timeout so the caller can check a stop flag.
    public static func acceptConnection(_ listener: Int32, waitMilliseconds: Int32) -> Int32? {
        var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, waitMilliseconds) > 0 else { return nil }
        let client = accept(listener, nil, nil)
        guard client >= 0 else {
            // Out of file descriptors: the pending connection stays queued, so back off instead of spinning.
            if errno == EMFILE || errno == ENFILE { usleep(100_000) }
            return nil
        }
        prepare(client)
        return client
    }

    private static func prepare(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, Int32(IPPROTO_TCP), Int32(TCP_NODELAY), &one, socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    /// Connects with a timeout; tries every address the name resolves to.
    public static func connect(host: String, port: Int, timeoutMilliseconds: Int32) -> Int32? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = streamType
        var results: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &results) == 0, let first = results else { return nil }
        defer { freeaddrinfo(results) }
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let info = current {
            defer { current = info.pointee.ai_next }
            let fd = socket(info.pointee.ai_family, streamType, info.pointee.ai_protocol)
            guard fd >= 0 else { continue }
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            var connected = sysConnect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0
            if !connected, errno == EINPROGRESS {
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&descriptor, 1, timeoutMilliseconds) > 0 {
                    var error: Int32 = 0
                    var length = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
                    connected = error == 0
                }
            }
            if connected {
                _ = fcntl(fd, F_SETFL, flags)
                prepare(fd)
                return fd
            }
            _ = sysClose(fd)
        }
        return nil
    }

    /// Reads at most `buffer.count` bytes; 0 at end of stream, negative on error (or timeout when one is set).
    public static func receive(_ fd: Int32, into buffer: inout [UInt8]) -> Int {
        buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
    }

    /// Writes everything; false when the peer is gone.
    @discardableResult
    public static func sendAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let written = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, noSignal)
            if written < 0 { if errno == EINTR { continue }; return false }
            if written == 0 { return false }
            offset += written
        }
        return true
    }

    public static func shutdownWrite(_ fd: Int32) { _ = shutdown(fd, Int32(SHUT_WR)) }
    public static func shutdownBoth(_ fd: Int32) { _ = shutdown(fd, Int32(SHUT_RDWR)) }
    public static func closeSocket(_ fd: Int32) { _ = sysClose(fd) }

    public static func setReceiveTimeout(_ fd: Int32, seconds: Double) {
        var value = timeval()
        value.tv_sec = Int(seconds)
        value.tv_usec = numericCast(Int((seconds - seconds.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }
}

#else

public enum LocalSockets {
    public static let isSupported = false
    public static func connect(host: String, port: Int, timeoutMilliseconds: Int32) -> Int32? { nil }
    public static func closeSocket(_ fd: Int32) {}
}

#endif

/// Small GET client for the pollers: short timeouts, small bodies, no redirects, no TLS.
public enum LocalHTTP {
    public struct Response { public let status: Int; public let body: Data }

    /// True when something accepts connections on host:port.
    public static func portAnswers(host: String = "127.0.0.1", port: Int, timeoutMilliseconds: Int32 = 300) -> Bool {
        guard let fd = LocalSockets.connect(host: host, port: port, timeoutMilliseconds: timeoutMilliseconds) else { return false }
        LocalSockets.closeSocket(fd)
        return true
    }

    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
    public static func get(host: String = "127.0.0.1", port: Int, path: String, headers: [String: String] = [:],
                           timeout: Double = 2, maxBytes: Int = 2 * 1_048_576) -> Response? {
        guard let fd = LocalSockets.connect(host: host, port: port, timeoutMilliseconds: Int32(timeout * 1000)) else { return nil }
        defer { LocalSockets.closeSocket(fd) }
        LocalSockets.setReceiveTimeout(fd, seconds: timeout)
        var request = "GET \(path) HTTP/1.1\r\nHost: \(host):\(port)\r\nConnection: close\r\nAccept: */*\r\nUser-Agent: QuotaPilot\r\n"
        for (name, value) in headers { request += "\(name): \(value)\r\n" }
        request += "\r\n"
        let sent = Array(request.utf8).withUnsafeBytes { LocalSockets.sendAll(fd, $0) }
        guard sent else { return nil }
        let parser = HTTPStreamParser(role: .response)
        var status = 0, body = Data(), ended = false
        parser.onHead = { status = $0.status }
        parser.onBody = { if body.count < maxBytes { body.append($0) } }
        parser.onMessageEnd = { ended = true }
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let deadline = Date().addingTimeInterval(timeout * 2)
        while !ended, Date() < deadline {
            let count = LocalSockets.receive(fd, into: &buffer)
            if count <= 0 { break }
            parser.feed(Data(buffer[0..<count]))
            if body.count >= maxBytes { break }
        }
        parser.finish()
        return status == 0 ? nil : Response(status: status, body: body)
    }
    #else
    public static func get(host: String = "127.0.0.1", port: Int, path: String, headers: [String: String] = [:],
                           timeout: Double = 2, maxBytes: Int = 2 * 1_048_576) -> Response? { nil }
    #endif
}
