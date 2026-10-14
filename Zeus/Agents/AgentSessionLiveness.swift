import Darwin
import Foundation

/// Identifies a dead agent lifetime, distinguishing helper disconnects from PID reuse.
enum AgentSessionLiveness {
    static func isDead(_ key: String) -> Bool {
        guard let suffix = key.split(separator: "#").last else { return false }
        let parts = suffix.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let pid = Int32(parts[0]), pid > 0, let start = UInt64(parts[1]), start > 0 else { return false }
        var info = proc_bsdinfo()
        let size = MemoryLayout.size(ofValue: info)
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size {
            return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec != start
        }
        // Permission errors are unknown, not proof of death.
        return kill(pid, 0) != 0 && errno == ESRCH
    }
}
