#if DEBUG
import Foundation

/// Verification seams: launch arguments that put the app in a known state so an agent
/// can prove behavior without synthetic taps. DEBUG-only; `debug-fences.py` fails the
/// build check if any argument read escapes this fence.
enum LaunchSeams {
    static func has(_ flag: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains(flag)
    }

    /// The value after a flag: `-OpenItem 3` → "3".
    static func value(after flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }
}
#endif
