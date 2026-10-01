import Foundation
import Darwin

// The header's left card — what THIS MACHINE is doing, beside what the Claude
// subscription is doing. Both figures come straight from the kernel: no spawn, no
// helper process, no permission prompt, and (see the no-network red line in
// CLAUDE.md) nothing that opens a connection. `host_statistics` is a mach trap.

/// One sample. `nil` until the second call — CPU is a rate, so the first sample
/// can only establish a baseline.
struct SystemLoad {
    let cpuPct: Int          // 0–100, normalized across every logical core
    let cores: Int           // logical cores, for the "3.4c" footnote
    let memPct: Int          // 0–100
    let memUsedBytes: UInt64
    let memTotalBytes: UInt64
}

/// Samples CPU and memory for the header. One shared instance; `sample()` is
/// called from the poll loop and `latest` is read when the header redraws.
///
/// **CPU is normalized to 0–100 across all cores**, which is Apple's own
/// convention for a whole-machine figure — Activity Monitor's System + User +
/// Idle add up to 100%. The other scale, where a busy 8-core box reads 800%,
/// belongs to the *process* list; a gauge on that scale has no meaningful full.
///
/// Known limit, worth reading before trusting the number: on Apple Silicon this
/// is "cycles not spent idle". It neither separates P cores from E cores nor
/// accounts for frequency, so background work parked on the E cores can read high
/// while costing almost no throughput. That's exactly why the row carries the
/// core-count footnote — "3.4c" restores the scale the percentage throws away.
final class SystemMonitor {
    static let shared = SystemMonitor()
    private init() {}

    /// The last real reading. Demo mode substitutes for it in `latest` rather than
    /// here, so switching demo off returns the true figure immediately instead of
    /// waiting a poll for a fresh baseline.
    private(set) var measured: SystemLoad?
    var latest: SystemLoad? { Demo.enabled ? Demo.systemLoad() : measured }
    private var prevTicks: (used: UInt64, total: UInt64)?

    func sample() {
        guard let ticks = cpuTicks(), let mem = memory() else { return }
        let prev = prevTicks
        prevTicks = ticks
        // First call establishes the baseline and reports nothing; the header shows
        // "—" for one poll rather than a bogus since-boot average.
        guard let p = prev else { return }
        let dUsed = ticks.used &- p.used
        let dTotal = ticks.total &- p.total
        guard dTotal > 0 else { return }

        let cpu = min(100, max(0, Int((Double(dUsed) / Double(dTotal) * 100).rounded())))
        let memPct = mem.total > 0
            ? min(100, max(0, Int((Double(mem.used) / Double(mem.total) * 100).rounded())))
            : 0
        measured = SystemLoad(cpuPct: cpu,
                              cores: ProcessInfo.processInfo.activeProcessorCount,
                              memPct: memPct,
                              memUsedBytes: mem.used,
                              memTotalBytes: mem.total)
    }

    /// Cumulative CPU ticks since boot, aggregated over every core. Used/total, so
    /// the caller differences two samples to get a rate.
    private func cpuTicks() -> (used: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size
                                           / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // cpu_ticks is a fixed-size C tuple indexed by CPU_STATE_*:
        // 0 = USER, 1 = SYSTEM, 2 = IDLE, 3 = NICE.
        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        let busy = user &+ system &+ nice
        return (busy, busy &+ idle)
    }

    /// Bytes in use, on Activity Monitor's own definition of "Memory Used":
    /// app memory (anonymous pages that aren't purgeable) + wired + compressed.
    ///
    /// The subtraction matters. macOS deliberately fills otherwise-idle RAM with
    /// reclaimable file cache and purgeable pages, so a naive total-minus-free
    /// reads near 100% on a perfectly healthy Mac. Apple's own guidance goes
    /// further — it says free memory isn't a sign of health at all and points you
    /// at memory *pressure* instead. We show the used figure anyway because
    /// pressure is a three-level enum with no public formula (it would be a
    /// footnote that never changes), but that's the reason this line is a rough
    /// "how full" and not a verdict on whether the machine needs more RAM.
    private func memory() -> (used: UInt64, total: UInt64)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size
                                           / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        let anonymous = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = anonymous > purgeable ? anonymous - purgeable : 0
        let used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return (used, ProcessInfo.processInfo.physicalMemory)
    }
}
