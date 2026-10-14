import Darwin
import Foundation

/// Captures the launching agent's lifetime identity without terminal environment variables.
public enum AgentProcessIdentity {
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
