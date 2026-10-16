import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Platform-neutral helpers so the core builds on macOS, Linux and Windows.
public enum Portable {
    public struct FileStatus { public let isRegular: Bool; public let size: UInt64; public let modified: Double }

    /// File type, size and modification time. Uses POSIX `stat` where available, because
    /// `FileManager.attributesOfItem` can take ~100 ms per file on some volumes.
    public static func status(_ path: String) -> FileStatus? {
        #if canImport(Darwin)
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileStatus(isRegular: (info.st_mode & S_IFMT) == S_IFREG, size: UInt64(info.st_size),
                          modified: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
        #elseif canImport(Glibc) || canImport(Musl)
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileStatus(isRegular: (info.st_mode & S_IFMT) == S_IFREG, size: UInt64(info.st_size),
                          modified: Double(info.st_mtim.tv_sec) + Double(info.st_mtim.tv_nsec) / 1e9)
        #else
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return FileStatus(isRegular: attributes[.type] as? FileAttributeType == .typeRegular,
                          size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                          modified: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        #endif
    }

    /// Lowercase hex SHA-256 (FIPS 180-4), implemented in Swift so it does not depend on CryptoKit.
    public static func sha256Hex(_ text: String) -> String {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]
        var message = Array(text.utf8)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { message.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift))) }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        for chunk in stride(from: 0, to: message.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(message[j]) << 24 | UInt32(message[j + 1]) << 16 | UInt32(message[j + 2]) << 8 | UInt32(message[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let t1 = hh &+ (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) &+ ((e & f) ^ (~e & g)) &+ k[i] &+ w[i]
                let t2 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) &+ ((a & b) ^ (a & c) ^ (b & c))
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
        }
        return h.map { String(format: "%08x", $0) }.joined()
    }

    /// Per-user state folder: Application Support on macOS, XDG state on Linux, LocalAppData on Windows.
    public static func stateDirectory(environment env: [String: String] = ProcessInfo.processInfo.environment,
                                      home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        #if os(macOS)
        return home.appendingPathComponent("Library/Application Support/QuotaPilot", isDirectory: true)
        #elseif os(Windows)
        let base = env["LOCALAPPDATA"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? home.appendingPathComponent("AppData/Local", isDirectory: true)
        return base.appendingPathComponent("QuotaPilot", isDirectory: true)
        #else
        let base = env["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".local/state", isDirectory: true)
        return base.appendingPathComponent("quotapilot", isDirectory: true)
        #endif
    }
}
