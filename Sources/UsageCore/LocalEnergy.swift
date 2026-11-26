import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Electricity cost of local model runs (docs/local-llm.md, "Electricity") and the coarse hardware description used by
// opt-in sharing (PRIVACY.md, "Local runs"). Nothing here is sent anywhere by itself.

/// What this computer is, as far as it can be told without administrator rights. Raw strings stay on the computer; the
/// `shared…` properties are the coarse values a report may carry.
public struct HardwareInfo: Equatable {
    /// "macos", "linux", "windows" or "other".
    public var os: String
    public var osMajor: Int
    /// The CPU's own name ("Apple M4 Max", "AMD Ryzen 9 7950X"). Shown locally only.
    public var cpuName: String?
    public var memoryGiB: Double
    /// GPU core count where the system tells it cheaply (Apple silicon).
    public var gpuCores: Int?

    public init(os: String, osMajor: Int, cpuName: String?, memoryGiB: Double, gpuCores: Int? = nil) {
        self.os = os; self.osMajor = osMajor; self.cpuName = cpuName; self.memoryGiB = memoryGiB; self.gpuCores = gpuCores
    }

    /// Apple silicon name parts: ("M4", "Max"), nil for anything else.
    var appleSilicon: (generation: String, tier: String)? {
        guard let name = cpuName,
              let match = name.range(of: #"^Apple (M[0-9]{1,2})( Pro| Max| Ultra)?\b"#, options: .regularExpression) else { return nil }
        let text = String(name[match])
        let parts = text.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return nil }
        return (parts[1], parts.count >= 3 ? parts[2] : "")
    }
    public var isAppleSilicon: Bool { appleSilicon != nil }

    /// "Apple M4 Max" for Apple silicon; for other computers only the vendor class, which is coarse enough not to single anyone out.
    public var sharedChip: String? {
        if let apple = appleSilicon { return "Apple " + apple.generation + (apple.tier.isEmpty ? "" : " " + apple.tier) }
        guard let name = cpuName?.lowercased() else { return nil }
        if name.contains("intel") { return "Intel" }
        if name.contains("amd") || name.contains("ryzen") || name.contains("epyc") { return "AMD" }
        if name.contains("qualcomm") || name.contains("snapdragon") { return "Qualcomm" }
        return "Other"
    }

    public static let memoryTiers = [8, 16, 24, 32, 48, 64, 96, 128, 192, 256]
    /// Memory as the smallest standard size that holds it (a 16 GB Mac reports 16.0, a Linux box with 16 GB installed about 15.6).
    public var sharedMemoryTier: Int {
        for tier in Self.memoryTiers where memoryGiB <= Double(tier) + 0.3 { return tier }
        return 256
    }
    /// "Up to" GPU core buckets: the smallest of 10, 20, 40, 80 that holds the count.
    public var sharedGPUCoreBucket: Int? {
        guard let cores = gpuCores, cores > 0 else { return nil }
        return [10, 20, 40, 80].first { cores <= $0 } ?? 80
    }
    /// An operating system family for the report; Linux has no meaningful major version to share.
    public var sharedOS: (family: String, major: Int) { (["macos", "linux", "windows"].contains(os) ? os : "other", os == "linux" ? 0 : min(max(osMajor, 0), 99)) }

    private static let cacheLock = NSLock()
    private static var cached: HardwareInfo?
    /// Detected once per process. macOS uses sysctl and one `ioreg` read for the GPU cores; Linux reads /proc; elsewhere the
    /// processor name from the environment where there is one. Missing values are nil, never guessed.
    public static func current() -> HardwareInfo {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cached { return cached }
        let value = detect()
        cached = value
        return value
    }

    static func detect() -> HardwareInfo {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let memory = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        #if os(macOS)
        return HardwareInfo(os: "macos", osMajor: version.majorVersion, cpuName: sysctlString("machdep.cpu.brand_string"), memoryGiB: memory, gpuCores: appleGPUCores())
        #elseif os(Linux)
        return HardwareInfo(os: "linux", osMajor: 0, cpuName: linuxCPUName(), memoryGiB: memory)
        #elseif os(Windows)
        return HardwareInfo(os: "windows", osMajor: version.majorVersion, cpuName: ProcessInfo.processInfo.environment["PROCESSOR_IDENTIFIER"], memoryGiB: memory)
        #else
        return HardwareInfo(os: "other", osMajor: 0, cpuName: nil, memoryGiB: memory)
        #endif
    }

    #if os(macOS)
    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
    /// `"gpu-core-count" = 40` in the AGX accelerator's registry entry; nil on Intel Macs and when ioreg is unavailable.
    private static func appleGPUCores() -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-r", "-d", "1", "-c", "AGXAccelerator"]
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard let range = text.range(of: #"\"gpu-core-count\" = [0-9]+"#, options: .regularExpression) else { return nil }
        return Int(text[range].split(separator: " ").last ?? "")
    }
    #endif

    #if os(Linux)
    private static func linuxCPUName() -> String? {
        guard let text = try? String(contentsOfFile: "/proc/cpuinfo", encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, ["model name", "Hardware", "Model"].contains(parts[0]), !parts[1].isEmpty { return parts[1] }
        }
        return nil
    }
    #endif
}

/// Typical power draw while a computer runs a local model. macOS cannot read real power without administrator rights
/// (`powermetrics` needs sudo), so the default is a typical whole-system figure for the chip class; the user can change it.
public enum DevicePower {
    public struct Estimate: Equatable {
        public let watts: Double
        /// What the figure is based on, for display ("Apple M4 Max").
        public let basis: String
    }

    /// Whole-system watts under sustained inference by Apple silicon tier. Rough, rounded figures from public measurements
    /// of Mac mini, MacBook Pro and Mac Studio under LLM load; the generation matters less than the tier.
    public static let appleTierWatts: [(tier: String, watts: Double)] = [("", 20), ("Pro", 40), ("Max", 70), ("Ultra", 120)]
    /// For a Mac without Apple silicon, a PC or a server whose GPU is not known: a typical desktop or laptop under load.
    public static let genericWatts: Double = 100

    public static func estimate(for hardware: HardwareInfo) -> Estimate {
        if let apple = hardware.appleSilicon {
            let watts = appleTierWatts.first { $0.tier == apple.tier }?.watts ?? genericWatts
            return Estimate(watts: watts, basis: "Apple " + apple.generation + (apple.tier.isEmpty ? "" : " " + apple.tier))
        }
        return Estimate(watts: genericWatts, basis: hardware.cpuName ?? hardware.os)
    }
}

/// The user's electricity settings. Everything is optional: with no price nothing about electricity is computed or shown.
public struct EnergySettings: Codable, Equatable {
    /// Price of one kWh in `currency`. Empty (nil) until the user enters it: there is no default.
    public var pricePerKWh: Double? = nil
    /// ISO 4217 code; nil means the one from the system region.
    public var currency: String? = nil
    /// Device power in watts; nil means the typical value for this computer.
    public var watts: Double? = nil
    /// Units of `currency` per 1 USD, to show cloud prices (which are in USD) in the same currency. Optional.
    public var usdRate: Double? = nil
    public init() {}

    public var hasPrice: Bool { (pricePerKWh ?? 0) > 0 }

    public static func isValidCurrency(_ code: String) -> Bool { code.range(of: #"^[A-Z]{3}$"#, options: .regularExpression) != nil }

    /// The system region's currency (USD when it cannot be told).
    public static func systemCurrency(_ locale: Locale = .current) -> String {
        #if canImport(Darwin)
        if #available(macOS 13, *), let code = locale.currency?.identifier, isValidCurrency(code) { return code }
        #else
        if let code = locale.currencyCode, isValidCurrency(code) { return code }
        #endif
        return "USD"
    }
    public func resolvedCurrency(_ locale: Locale = .current) -> String {
        if let currency, Self.isValidCurrency(currency.uppercased()) { return currency.uppercased() }
        return Self.systemCurrency(locale)
    }
    /// Watts to use: the user's value, else the typical one for this computer.
    public func resolvedWatts(_ hardware: HardwareInfo = .current()) -> Double {
        if let watts, watts > 0 { return watts }
        return DevicePower.estimate(for: hardware).watts
    }
    /// The USD→currency rate that applies: 1 for USD itself, the user's rate otherwise, nil when unknown.
    public func rate(_ locale: Locale = .current) -> Double? {
        if resolvedCurrency(locale) == "USD" { return 1 }
        if let usdRate, usdRate > 0 { return usdRate }
        return nil
    }

    /// Problems with a value the user typed, or nil.
    public static func validate(price: Double? = nil, watts: Double? = nil, rate: Double? = nil, currency: String? = nil) -> String? {
        if let price, !(price >= 0 && price <= 100_000) { return "price per kWh must be between 0 and 100000" }
        if let watts, !(watts >= 1 && watts <= 5000) { return "power must be between 1 and 5000 W" }
        if let rate, !(rate > 0 && rate <= 10_000_000) { return "exchange rate must be a positive number" }
        if let currency, !isValidCurrency(currency.uppercased()) { return "currency must be a three-letter ISO code such as USD, EUR or JPY" }
        return nil
    }
}

extension LocalLLMSettings {
    public var energySettings: EnergySettings {
        get { energy ?? EnergySettings() }
        set { energy = newValue }
    }
}

/// Electricity used by the measured local inference time of some events, and what it costs.
public struct LocalEnergyReport: Equatable {
    /// Inference seconds the events measured.
    public let seconds: Double
    public let watts: Double
    public let kWh: Double
    /// Tokens of the events that carry a measured time, and of all events.
    public let measuredTokens: Double
    public let totalTokens: Double
    public let currency: String
    /// Electricity cost in `currency`; nil while no price is set.
    public let cost: Double?
    public let costPerMillionTokens: Double?
    /// The hypothetical cloud cost of the same events converted into `currency`; nil without a known exchange rate.
    public let cloudCost: Double?
    public let cloudCostPerMillionTokens: Double?
    public let cloudCostUSD: Double
    public let cloudPerMillionTokensUSD: Double?
    public var isEmpty: Bool { seconds <= 0 }
    /// Share of the tokens whose time was measured (some servers report tokens without any timing).
    public var coverage: Double { totalTokens > 0 ? measuredTokens / totalTokens : 0 }

    public init(events: [LocalLLMEvent], reference: String?, settings: EnergySettings, hardware: HardwareInfo = .current(), locale: Locale = .current) {
        var seconds = 0.0, measured = 0.0, total = 0.0
        var measuredPrompt = 0.0, measuredCached = 0.0, measuredCompletion = 0.0
        for event in events {
            total += event.prompt + event.completion
            let time = event.seconds ?? ((event.promptSeconds ?? 0) + (event.genSeconds ?? 0))
            guard time > 0, time.isFinite else { continue }
            seconds += time
            measured += event.prompt + event.completion
            measuredPrompt += event.prompt; measuredCached += event.cached; measuredCompletion += event.completion
        }
        let watts = settings.resolvedWatts(hardware)
        let kWh = seconds / 3600 * watts / 1000
        self.seconds = seconds; self.watts = watts; self.kWh = kWh
        measuredTokens = measured; totalTokens = total
        currency = settings.resolvedCurrency(locale)
        let price = settings.hasPrice ? settings.pricePerKWh : nil
        cost = price.map { kWh * $0 }
        costPerMillionTokens = cost.flatMap { measured > 0 ? $0 / (measured / 1_000_000) : nil }
        let model = LocalLLMReference.resolve(reference)
        let cloudUSD = LocalLLMReport.cost(prompt: measuredPrompt, cached: measuredCached, completion: measuredCompletion, price: model)
        let cloudPerMillion: Double? = measured > 0 ? cloudUSD / (measured / 1_000_000) : nil
        cloudCostUSD = cloudUSD
        cloudPerMillionTokensUSD = cloudPerMillion
        let rate = settings.rate(locale)
        cloudCost = rate.map { cloudUSD * $0 }
        cloudCostPerMillionTokens = rate.flatMap { r in cloudPerMillion.map { $0 * r } }
    }
}
