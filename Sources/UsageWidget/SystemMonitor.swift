import Foundation
import IOKit

/// CPU, GPU, temperature, memory and disk readings for the optional system line on the card.
/// Everything is read without elevated privileges: Mach host statistics, IOKit accelerator statistics,
/// the IOHID temperature sensors (Apple silicon), and the boot volume's capacity.
struct SystemSnapshot {
    var cpuPercent: Double?
    var gpuPercent: Double?
    var temperatureC: Double?
    var memoryPercent: Double?
    var diskPercent: Double?
}

final class SystemMonitor {
    private var previousTicks: [UInt32]?

    func sample() -> SystemSnapshot {
        SystemSnapshot(cpuPercent: cpu(), gpuPercent: gpu(), temperatureC: temperature(), memoryPercent: memory(), diskPercent: disk())
    }

    /// Busy share of all cores since the previous sample (user + system + nice).
    private func cpu() -> Double? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        var ticks: [UInt32] = []
        for cpu in 0..<Int(count) {
            for state in 0..<Int(CPU_STATE_MAX) { ticks.append(UInt32(bitPattern: info[cpu * Int(CPU_STATE_MAX) + state])) }
        }
        defer { previousTicks = ticks }
        guard let previous = previousTicks, previous.count == ticks.count else { return nil }
        var busy: UInt64 = 0, total: UInt64 = 0
        for cpu in 0..<Int(count) {
            for state in 0..<Int(CPU_STATE_MAX) {
                let i = cpu * Int(CPU_STATE_MAX) + state
                let delta = UInt64(ticks[i] &- previous[i])
                total += delta
                if state != Int(CPU_STATE_IDLE) { busy += delta }
            }
        }
        return total > 0 ? Double(busy) / Double(total) * 100 : nil
    }

    /// GPU "Device Utilization %" from the IOAccelerator performance statistics.
    private func gpu() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] else { continue }
            let value = (stats["Device Utilization %"] ?? stats["GPU Activity(%)"]) as? NSNumber
            if let value { best = max(best ?? 0, value.doubleValue) }
        }
        return best
    }

    /// Hottest die sensor reported through IOHID (Apple silicon); nil when no sensor is readable.
    private func temperature() -> Double? {
        guard let client = HIDSensors.create() else { return nil }
        return HIDSensors.maxTemperature(client)
    }

    /// App + wired + compressed memory over physical memory, like Activity Monitor's "Memory Used".
    private func memory() -> Double? {
        var stats = vm_statistics64()
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = Double(vm_kernel_page_size)
        let used = (Double(stats.internal_page_count) - Double(stats.purgeable_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        return total > 0 ? min(100, max(0, used / total * 100)) : nil
    }

    /// Used share of the boot volume (available space counts purgeable space, as Finder does).
    private func disk() -> Double? {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        guard let total = values?.volumeTotalCapacity, total > 0,
              let available = values?.volumeAvailableCapacityForImportantUsage else { return nil }
        return min(100, max(0, (1 - Double(available) / Double(total)) * 100))
    }
}

/// IOHIDEventSystem temperature sensors. These functions are exported by IOKit but not in the public headers.
private enum HIDSensors {
    typealias Client = OpaquePointer
    @_silgen_name("IOHIDEventSystemClientCreate") static func clientCreate(_ allocator: CFAllocator?) -> Unmanaged<AnyObject>?
    @_silgen_name("IOHIDEventSystemClientSetMatching") static func setMatching(_ client: AnyObject, _ matching: CFDictionary) -> Int32
    @_silgen_name("IOHIDEventSystemClientCopyServices") static func copyServices(_ client: AnyObject) -> Unmanaged<CFArray>?
    @_silgen_name("IOHIDServiceClientCopyEvent") static func copyEvent(_ service: AnyObject, _ type: Int64, _ options: Int32, _ timeout: Int64) -> Unmanaged<AnyObject>?
    @_silgen_name("IOHIDServiceClientCopyProperty") static func copyProperty(_ service: AnyObject, _ key: CFString) -> Unmanaged<AnyObject>?
    @_silgen_name("IOHIDEventGetFloatValue") static func floatValue(_ event: AnyObject, _ field: Int32) -> Double

    static let temperatureType: Int64 = 15

    static func create() -> AnyObject? {
        guard let client = clientCreate(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        _ = setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        return client
    }

    static func maxTemperature(_ client: AnyObject) -> Double? {
        guard let services = copyServices(client)?.takeRetainedValue() as? [AnyObject] else { return nil }
        var die: [Double] = [], all: [Double] = []
        for service in services {
            guard let event = copyEvent(service, temperatureType, 0, 0)?.takeRetainedValue() else { continue }
            let value = floatValue(event, Int32(temperatureType << 16))
            guard value > 0, value < 130 else { continue }
            all.append(value)
            let name = (copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String ?? "").lowercased()
            if name.contains("tdie") || name.contains("cpu") || name.contains("soc") || name.contains("pacc") || name.contains("eacc") { die.append(value) }
        }
        return (die.isEmpty ? all : die).max()
    }
}
