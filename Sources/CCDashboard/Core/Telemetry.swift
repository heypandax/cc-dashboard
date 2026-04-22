import FirebaseAnalytics
import FirebaseCore
import FirebaseCrashlytics
import Foundation

/// Analytics + Crashlytics 的唯一封装。业务代码 call `Telemetry.track(...)` 不直接 import Firebase,
/// 方便后续替换/关停。遵守"只上报枚举级元数据(tool / risk / decision),不带用户内容"的隐私约定。
enum Telemetry {
    enum Event: String {
        case appLaunch         = "app_launch"
        case approvalShown     = "approval_shown"
        case approvalDecided   = "approval_decided"
        case allowAllUsed      = "allow_all_used"
        case autoAllowSet      = "auto_allow_set"
    }

    enum Key: String {
        case tool, risk, decision, count, minutes, version, phase
        case trustMinutes = "trust_minutes"
    }

    /// UserDefaults key。命令行 opt-out:
    ///   defaults write com.heypanda.cc-dashboard analyticsEnabled 0
    private static let enabledKey = "analyticsEnabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// 启动时一次。Telemetry 是 Firebase 的唯一 seam —— 业务代码不需要 import FirebaseCore。
    static func configure() {
        FirebaseApp.configure()
    }

    static func track(_ event: Event, _ params: [Key: Any] = [:]) {
        guard isEnabled else { return }
        var dict: [String: Any] = [:]
        for (k, v) in params { dict[k.rawValue] = v }
        Analytics.logEvent(event.rawValue, parameters: dict)
    }

    static func recordError(_ error: Error, phase: String? = nil) {
        guard isEnabled else { return }
        let userInfo = phase.map { [Key.phase.rawValue: $0] }
        Crashlytics.crashlytics().record(error: error, userInfo: userInfo)
    }
}

extension Bundle {
    /// CFBundleShortVersionString(一般是 "0.1.0")。SwiftPM + 自组 bundle 流程偶尔拿不到,此时返回 nil。
    var appVersion: String? {
        infoDictionary?["CFBundleShortVersionString"] as? String
    }
}
