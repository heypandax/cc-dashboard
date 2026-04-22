import AppKit
import Sparkle
import SwiftUI

@main
struct CCDashboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window(MainSceneID.title, id: MainSceneID.id) {
            MainWindow(dashboard: AppState.shared.dashboard)
        }
        .windowResizability(.contentSize)
    }
}

/// SwiftUI Window 的配置 + 从 AppKit 侧找回它的 anchor。
/// appKitIdentifier 是 SwiftUI 内部生成的 NSWindow.identifier(`{id}-AppWindow-1`),
/// 未来 SwiftUI 换命名规则 title 作为兜底。
enum MainSceneID {
    static let id = "main"
    static let title = "cc-dashboard"
    static let appKitIdentifier = "main-AppWindow-1"

    @MainActor
    static func matches(_ w: NSWindow) -> Bool {
        w.identifier?.rawValue == appKitIdentifier || w.title == title
    }
}

/// Scene body 首次求值时就会通过 AppState.shared.dashboard 触发构造,
/// 因此 AppDelegate 不需要再显式 trigger。StatusBarController 同批建成。
@MainActor
final class AppState {
    static let shared = AppState()
    let dashboard: Dashboard
    let statusBar: StatusBarController
    let updaterController: SPUStandardUpdaterController

    private init() {
        // 必须最早配置 —— Crashlytics 要能捕到启动早期的 crash。
        // 读 bundle 里的 GoogleService-Info.plist;没拷进 bundle 时底层会 fatalError,
        // 本地 debug 先 `cp GoogleService-Info.plist .` 再 `./make-bundle.sh`。
        Telemetry.configure()

        // 一次性 Crashlytics onboarding / 符号化自测入口。仅 Debug 编译生效,发布的
        // DMG 里压根没这段代码 —— 避免用户误设 env var(或恶意 LaunchAgent 注入)导致 crash loop。
        // 用 NSException.raise 而不是 fatalError:Swift 的 trap 太快,Crashlytics signal handler
        // 来不及写完 report;ObjC exception 配 NSApplicationCrashOnExceptions=YES 走 SIGABRT,
        // Crashlytics 的 ObjC handler 能完整 capture 堆栈/二进制镜像/元数据。
        #if DEBUG
        if ProcessInfo.processInfo.environment["CC_TEST_CRASH"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                NSException(
                    name: .genericException,
                    reason: "crashlytics onboarding test — safe to ignore",
                    userInfo: nil
                ).raise()
            }
        }
        #endif

        let d = Dashboard()
        self.dashboard = d
        // Sparkle updater:startingUpdater: true 后台每 24h 查一次,用户也能手动触发。
        // delegate 留空走默认行为(签名校验 + UI 弹窗)。
        let updater = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.updaterController = updater
        self.statusBar = StatusBarController(dashboard: d, updater: updater)

        let version = Bundle.main.appVersion ?? "unknown"
        Telemetry.track(.appLaunch, [.version: version])
        // 每次进程起来都留一条 lifecycle 痕迹 —— 用来核对 auto-allow 失效是否发生在重启之后
        Log.lifecycle.notice("launched pid=\(ProcessInfo.processInfo.processIdentifier) version=\(version, privacy: .public)")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI Window 是唯一 Scene,启动会自动显示。LSUIElement 下用户期望
        // 看见的是状态栏而不是主窗口,在首个 runloop 把它按下去(对象保留,后续
        // openMainWindow 再 order-front-回来)。
        DispatchQueue.main.async {
            for w in NSApp.windows where MainSceneID.matches(w) {
                w.orderOut(nil)
            }
        }
    }

    // 关掉主窗口不应让 app 退出 —— 状态栏 app 的生命周期独立于窗口。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
