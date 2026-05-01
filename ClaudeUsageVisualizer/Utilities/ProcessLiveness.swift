import Darwin
import Foundation

enum ProcessLiveness {
    /// Returns true if a process with `pid` exists and we are allowed to signal it.
    /// Uses `kill(pid, 0)` which only checks existence; does not actually signal.
    static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        let result = kill(pid, 0)
        if result == 0 { return true }
        // EPERM = exists but we can't signal; still "alive"
        return errno == EPERM
    }
}
