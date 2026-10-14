import Darwin
import Foundation
import ZeusProtocol

/// Captures the launching agent's lifetime identity without terminal environment variables.
public enum AgentProcessIdentity {
    /// Hook commands can have an intermediate shell. Report a bounded ancestry,
    /// with process lifetimes, rather than guessing identity from cwd or a pane.
    public static func ancestors(pid: Int, limit: Int = 8) -> [HookProcessIdentity] {
        #if os(macOS)
        var result: [HookProcessIdentity] = [], current = pid
        for _ in 0..<max(0, min(limit, 16)) {
            guard let native = Int32(exactly: current), native > 1 else { break }
            var info = proc_bsdinfo()
            let size = MemoryLayout.size(ofValue: info)
            guard proc_pidinfo(native, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size, info.pbi_start_tvsec > 0 else { break }
            result.append(.init(pid: current, startTime: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec))
            guard info.pbi_ppid > 1, Int(info.pbi_ppid) != current else { break }
            current = Int(info.pbi_ppid)
        }
        return result
        #else
        return []
        #endif
    }
    /// Microseconds since Unix epoch, or nil if the process no longer exists or cannot be inspected.
    /// Zero must not be used as a production identity: it cannot protect against PID reuse.
    public static func startTime(pid: Int) -> UInt64? {
        #if os(macOS)
        guard let pid = Int32(exactly: pid), pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = MemoryLayout.size(ofValue: info)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
              info.pbi_start_tvsec > 0 else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
        #else
        return nil
        #endif
    }
}
