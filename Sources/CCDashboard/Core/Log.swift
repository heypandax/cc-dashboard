import os

/// 统一走 os.Logger (unified log)。诊断方式:
///   Console.app → 按 subsystem 过滤 `com.heypanda.cc-dashboard`
///   CLI:  log show --predicate 'subsystem == "com.heypanda.cc-dashboard"' --last 1h --info
///         log stream --predicate 'subsystem == "com.heypanda.cc-dashboard"'
enum Log {
    private static let subsystem = "com.heypanda.cc-dashboard"
    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    static let session   = Logger(subsystem: subsystem, category: "session")
    static let autoAllow = Logger(subsystem: subsystem, category: "auto-allow")
    static let approval  = Logger(subsystem: subsystem, category: "approval")
}
