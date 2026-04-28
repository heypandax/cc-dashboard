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
                // SwiftUI 给 Window 的默认 isReleasedWhenClosed 在不同 macOS 版本里
                // 行为不一致 —— 用户红点关一次后 NSApp.windows 就没它了,菜单栏"打开
                // 主窗口"再点就 silent no-op。强制 false,保证窗口对象常驻。
                w.isReleasedWhenClosed = false
                MainWindowGeometry.clampToVisibleScreens(w)
                w.orderOut(nil)
            }
        }
    }

    // 关掉主窗口不应让 app 退出 —— 状态栏 app 的生命周期独立于窗口。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// 处理主窗口的几何 —— SwiftUI `Window` 的 frame autosave 不感知屏幕拓扑变化,
/// 接过外屏再拔掉就会留下"窗口在 (1716, 29) 而当前屏幕只到 1440"的脏数据,
/// 表现为打开后窗口贴在屏幕最左边、或者干脆不可见。
@MainActor
enum MainWindowGeometry {
    /// 如果窗口当前 frame 跟任何可见屏幕都不相交,把它居中到主屏。
    /// 参考 AppKit 的 `NSWindow.constrainFrameRect(_:to:)` 但更激进 —— 那个 API 只夹边,
    /// 当窗口完全在另一块已断开的屏幕坐标系里时夹不动。
    static func clampToVisibleScreens(_ window: NSWindow) {
        let frame = window.frame
        if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
            return
        }
        guard let target = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = target.visibleFrame
        let origin = NSPoint(
            x: visible.midX - frame.width / 2,
            y: visible.midY - frame.height / 2
        )
        window.setFrameOrigin(origin)
    }
}
