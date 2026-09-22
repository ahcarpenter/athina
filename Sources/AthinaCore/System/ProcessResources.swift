import Darwin
import Foundation

/// A point-in-time reading of this process's CPU time and memory footprint.
public struct ProcessResourceSample: Equatable, Sendable {
    public var cpuSeconds: Double
    public var wallTime: Date
    public var footprintBytes: UInt64

    public init(cpuSeconds: Double, wallTime: Date, footprintBytes: UInt64) {
        self.cpuSeconds = cpuSeconds
        self.wallTime = wallTime
        self.footprintBytes = footprintBytes
    }
}

/// CPU percent over an interval (100 = one full core) plus current memory.
public struct ProcessResourceUsage: Equatable, Sendable {
    public var cpuPercent: Double
    public var footprintBytes: UInt64

    public init(cpuPercent: Double, footprintBytes: UInt64) {
        self.cpuPercent = cpuPercent
        self.footprintBytes = footprintBytes
    }

    /// Nil when the samples do not span a positive interval.
    public static func between(_ previous: ProcessResourceSample, _ current: ProcessResourceSample) -> ProcessResourceUsage? {
        let wall = current.wallTime.timeIntervalSince(previous.wallTime)
        guard wall > 0 else { return nil }
        let cpu = max(0, current.cpuSeconds - previous.cpuSeconds)
        return ProcessResourceUsage(cpuPercent: cpu / wall * 100, footprintBytes: current.footprintBytes)
    }
}

public enum ProcessResources {
    /// CPU seconds are real seconds, so a sample is taken on real time
    /// whatever clock the rest of the app runs on (`AthinaClock`).
    public static func sample(at now: Date = Date()) -> ProcessResourceSample {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        return ProcessResourceSample(cpuSeconds: cpu, wallTime: now, footprintBytes: physicalFootprint())
    }

    /// The same number Activity Monitor's Memory column shows.
    public static func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reboundPointer, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }
}
