import Foundation
import Darwin
import IOKit
import os.log

/// Collects system performance metrics (CPU, Memory, Disk, Network) using Darwin APIs.
///
/// All mutable state (previous CPU info, network snapshots) is protected by a serial
/// dispatch queue to prevent race conditions when `collect()` is called from concurrent
/// `Task.detached` contexts. The Mach VM buffer from `host_processor_info` must be
/// deallocated exactly once — a data race here causes a double-free crash.
nonisolated class SystemPerformanceProvider: @unchecked Sendable {

    /// Shared singleton so metrics and history survive page changes.
    /// The provider is expensive to create (Mach buffers, IOKit state) and
    /// all widget instances share the same system data anyway.
    static let shared = SystemPerformanceProvider()

    private let logger = Logger(subsystem: "com.ledge.app", category: "SystemPerformance")
    private let debugLog = DebugLogger(category: "SystemPerformance")

    struct Metrics: Sendable {
        var cpuUsage: Double = 0        // 0-100%
        var memoryUsed: Double = 0      // GB
        var memoryTotal: Double = 0     // GB
        var memoryPercent: Double = 0   // 0-100%
        var diskUsed: Double = 0        // GB
        var diskTotal: Double = 0       // GB
        var diskPercent: Double = 0     // 0-100%
        var diskReadBytesPerSec: Double = 0
        var diskWriteBytesPerSec: Double = 0
        var networkDownBytesPerSec: Double = 0
        var networkUpBytesPerSec: Double = 0
    }

    /// Serial queue protecting all mutable state (CPU info buffer, network snapshot).
    /// Prevents race conditions when overlapping Task.detached calls invoke collect().
    private let stateQueue = DispatchQueue(label: "com.ledge.SystemPerformanceProvider")

    // Previous CPU ticks for delta calculation — access ONLY on stateQueue
    private nonisolated(unsafe) var previousCPUInfo: processor_info_array_t?
    private nonisolated(unsafe) var previousCPUInfoCount: mach_msg_type_number_t = 0

    // Previous disk I/O snapshot for delta calculation — access ONLY on stateQueue
    private struct DiskIOSnapshot {
        var bytesRead: UInt64 = 0
        var bytesWritten: UInt64 = 0
        var timestamp: Date = Date()
    }
    private nonisolated(unsafe) var previousDiskIOSnapshot: DiskIOSnapshot?

    // Previous network snapshot for delta calculation — access ONLY on stateQueue
    private struct NetworkSnapshot {
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
        var timestamp: Date = Date()
    }
    private nonisolated(unsafe) var previousNetworkSnapshot: NetworkSnapshot?

    /// Collect current system metrics.
    /// Thread-safe: serialised via stateQueue to prevent overlapping access to
    /// the Mach VM buffer from host_processor_info.
    func collect() -> Metrics {
        stateQueue.sync {
            var m = Metrics()
            m.cpuUsage = collectCPU()
            (m.memoryUsed, m.memoryTotal, m.memoryPercent) = collectMemory()
            (m.diskUsed, m.diskTotal, m.diskPercent) = collectDisk()
            let diskIO = collectDiskIO()
            m.diskReadBytesPerSec = diskIO.read
            m.diskWriteBytesPerSec = diskIO.write
            let net = collectNetwork()
            m.networkDownBytesPerSec = net.down
            m.networkUpBytesPerSec = net.up
            return m
        }
    }

    // MARK: - CPU

    private func collectCPU() -> Double {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var cpuInfoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUs,
            &cpuInfo,
            &cpuInfoCount
        )

        guard result == KERN_SUCCESS, let info = cpuInfo else {
            debugLog.debug("Failed to get CPU info: \(result)")
            return 0
        }

        var totalUsage: Double = 0

        if let prev = previousCPUInfo {
            for i in 0..<Int(numCPUs) {
                let offset = Int(CPU_STATE_MAX) * i
                let userDelta = Double(info[offset + Int(CPU_STATE_USER)] - prev[offset + Int(CPU_STATE_USER)])
                let systemDelta = Double(info[offset + Int(CPU_STATE_SYSTEM)] - prev[offset + Int(CPU_STATE_SYSTEM)])
                let niceDelta = Double(info[offset + Int(CPU_STATE_NICE)] - prev[offset + Int(CPU_STATE_NICE)])
                let idleDelta = Double(info[offset + Int(CPU_STATE_IDLE)] - prev[offset + Int(CPU_STATE_IDLE)])

                let total = userDelta + systemDelta + niceDelta + idleDelta
                if total > 0 {
                    totalUsage += ((userDelta + systemDelta + niceDelta) / total) * 100.0
                }
            }
            totalUsage /= Double(numCPUs)

            // Deallocate previous
            let prevSize = vm_size_t(previousCPUInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: prev), prevSize)
        }

        previousCPUInfo = cpuInfo
        previousCPUInfoCount = cpuInfoCount

        return totalUsage
    }

    // MARK: - Memory

    private func collectMemory() -> (used: Double, total: Double, percent: Double) {
        let totalBytes = Double(ProcessInfo.processInfo.physicalMemory)
        let totalGB = totalBytes / (1024 * 1024 * 1024)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            debugLog.debug("Failed to get memory info: \(result)")
            return (0, totalGB, 0)
        }

        let pageSize = Double(vm_kernel_page_size)
        let activeBytes = Double(stats.active_count) * pageSize
        let wiredBytes = Double(stats.wire_count) * pageSize
        let compressedBytes = Double(stats.compressor_page_count) * pageSize

        let usedBytes = activeBytes + wiredBytes + compressedBytes
        let usedGB = usedBytes / (1024 * 1024 * 1024)
        let percent = (usedBytes / totalBytes) * 100.0

        return (usedGB, totalGB, percent)
    }

    // MARK: - Disk

    private func collectDisk() -> (used: Double, total: Double, percent: Double) {
        let fileManager = FileManager.default
        guard let attrs = try? fileManager.attributesOfFileSystem(forPath: "/"),
              let totalSpace = attrs[.systemSize] as? Int64,
              let freeSpace = attrs[.systemFreeSize] as? Int64 else {
            return (0, 0, 0)
        }

        let totalGB = Double(totalSpace) / (1024 * 1024 * 1024)
        let freeGB = Double(freeSpace) / (1024 * 1024 * 1024)
        let usedGB = totalGB - freeGB
        let percent = (usedGB / totalGB) * 100.0

        return (usedGB, totalGB, percent)
    }

    // MARK: - Disk I/O

    private func collectDiskIO() -> (read: Double, write: Double) {
        let current = takeDiskIOSnapshot()
        defer { previousDiskIOSnapshot = current }

        guard let prev = previousDiskIOSnapshot else { return (0, 0) }

        let elapsed = current.timestamp.timeIntervalSince(prev.timestamp)
        guard elapsed > 0 else { return (0, 0) }

        let readDelta = current.bytesRead >= prev.bytesRead ? current.bytesRead - prev.bytesRead : current.bytesRead
        let writeDelta = current.bytesWritten >= prev.bytesWritten ? current.bytesWritten - prev.bytesWritten : current.bytesWritten

        return (
            read: Double(readDelta) / elapsed,
            write: Double(writeDelta) / elapsed
        )
    }

    private func takeDiskIOSnapshot() -> DiskIOSnapshot {
        var snapshot = DiskIOSnapshot()

        // Use iostat-style approach: read from sysctl kern.devstat or
        // iterate IOKit's IOBlockStorageDriver statistics
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else { return snapshot }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return snapshot
        }
        defer { IOObjectRelease(iterator) }

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }

            guard let props = getProperties(for: entry),
                  let stats = props["Statistics"] as? [String: Any] else { continue }

            if let bytesRead = stats["Bytes (Read)"] as? UInt64 {
                snapshot.bytesRead += bytesRead
            }
            if let bytesWritten = stats["Bytes (Write)"] as? UInt64 {
                snapshot.bytesWritten += bytesWritten
            }
        }

        snapshot.timestamp = Date()
        return snapshot
    }

    private func getProperties(for service: io_object_t) -> [String: Any]? {
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return dict
    }

    // MARK: - Network (WiFi / en0)

    private func collectNetwork() -> (down: Double, up: Double) {
        let current = takeNetworkSnapshot()
        defer { previousNetworkSnapshot = current }

        guard let prev = previousNetworkSnapshot else { return (0, 0) }

        let elapsed = current.timestamp.timeIntervalSince(prev.timestamp)
        guard elapsed > 0 else { return (0, 0) }

        // Handle counter wrap-around
        let bytesInDelta = current.bytesIn >= prev.bytesIn ? current.bytesIn - prev.bytesIn : current.bytesIn
        let bytesOutDelta = current.bytesOut >= prev.bytesOut ? current.bytesOut - prev.bytesOut : current.bytesOut

        return (
            down: Double(bytesInDelta) / elapsed,
            up: Double(bytesOutDelta) / elapsed
        )
    }

    private func takeNetworkSnapshot() -> NetworkSnapshot {
        var snapshot = NetworkSnapshot()

        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return snapshot }
        defer { freeifaddrs(ifaddrPtr) }

        var current: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let ifa = current {
            let name = String(cString: ifa.pointee.ifa_name)
            if name == "en0",
               ifa.pointee.ifa_addr.pointee.sa_family == UInt8(AF_LINK),
               let data = ifa.pointee.ifa_data {
                let ifData = data.assumingMemoryBound(to: if_data.self)
                snapshot.bytesIn = UInt64(ifData.pointee.ifi_ibytes)
                snapshot.bytesOut = UInt64(ifData.pointee.ifi_obytes)
                break
            }
            current = ifa.pointee.ifa_next
        }

        snapshot.timestamp = Date()
        return snapshot
    }
}
