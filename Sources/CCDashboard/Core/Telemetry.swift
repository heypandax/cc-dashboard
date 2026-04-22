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

    /// 只有在 bundle 里找到 GoogleService-Info.plist **且**未被用户 opt-out 时才真正 configure。
    /// 否则 track / recordError 全部 no-op —— 避免 CI build 漏带 plist / 第三方分发 / opt-out
    /// 情况下 FirebaseApp.configure() 抛 NSException 让 app 启动即崩。
    ///
    /// nonisolated(unsafe):configure() 只从 @MainActor AppState.init 调用一次(写),
    /// 之后 track/recordError 从任意线程读。单次写 + 多次读,无 race。
    nonisolated(unsafe) private static var configured = false

    /// 启动时一次。Telemetry 是 Firebase 的唯一 seam —— 业务代码不需要 import FirebaseCore。
    static func configure() {
        guard isEnabled else { return }
        guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else {
            // 缺配置文件(开源二进制 / 漏配 CI secret),静默跳过,app 继续
            return
        }
        FirebaseApp.configure()
        configured = true
    }

    static func track(_ event: Event, _ params: [Key: Any] = [:]) {
        guard configured else { return }
        var dict: [String: Any] = [:]
        for (k, v) in params { dict[k.rawValue] = v }
        Analytics.logEvent(event.rawValue, parameters: dict)
    }

    static func recordError(_ error: Error, phase: String? = nil) {
        guard configured else { return }
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
