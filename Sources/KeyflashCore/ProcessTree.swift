import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Looks up a process's parents, so an alert can say which app the agent runs in.
public enum ProcessTree {
    /// The parent of `pid`, or nil if it can't be determined (or is launchd/init).
    public static func parent(of pid: Int) -> Int? {
        #if canImport(Darwin)
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(truncatingIfNeeded: pid)]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let ppid = Int(info.kp_eproc.e_ppid)
        return ppid > 1 ? ppid : nil
        #else
        // /proc/<pid>/stat: "pid (comm) state ppid ..." — comm may contain spaces or ')'.
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let close = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        guard fields.count > 1, let ppid = Int(fields[1]), ppid > 1 else { return nil }
        return ppid
        #endif
    }

    /// `pid` itself, then its parent, grandparent, ... (stops at launchd/init or `limit`).
    public static func ancestors(startingAt pid: Int, limit: Int = 32) -> [Int] {
        var result: [Int] = []
        var current = pid
        while result.count < limit, current > 1 {
            result.append(current)
            guard let next = parent(of: current), next != current, !result.contains(next) else { break }
            current = next
        }
        return result
    }
}
