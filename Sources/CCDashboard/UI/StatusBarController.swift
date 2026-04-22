import AppKit
import Observation
import Sparkle
import SwiftUI

/// 自管 NSStatusItem + NSPanel,为了拿回 `hidesOnDeactivate` 的控制权:
/// pin 时 panel 常驻,unpin 时靠全局鼠标监听在点击外部时关闭。
@MainActor
@Observable
final class StatusBarController {
    let dashboard: Dashboard
    let updater: SPUStandardUpdaterController
    var isPinned: Bool = false {
        didSet { refreshClickMonitor() }
    }

    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var hostingController: NSHostingController<MenuBarView>!
    private var clickMonitor: Any?
    private var lastAppliedIconState: MenuBarIconState?

    init(dashboard: Dashboard, updater: SPUStandardUpdaterController) {
        self.dashboard = dashboard
        self.updater = updater
        setupStatusItem()
        setupPanel()
        trackIconState()
    }

    func checkForUpdates() {
        updater.checkForUpdates(nil)
    }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = MenuBarIconRenderer.image(for: .idle)
            button.target = self
            button.action = #selector(statusItemClicked(_:))
        }
        self.statusItem = item
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    // MARK: - Panel

    private func setupPanel() {
        let controller = NSHostingController(
            rootView: MenuBarView(dashboard: dashboard, controller: self)
        )
        // 让 controller.view 按 SwiftUI 的 fittingSize 自适应,panel 后续随它缩放。
        controller.sizingOptions = [.preferredContentSize]
        // titled panel 会给 SwiftUI content 一个 ~28pt 的 top safe-area inset(留给 titlebar),
        // 就算 .fullSizeContentView + 透明标题栏也还是留着。关掉 safe-area 让内容贴到顶。
        controller.safeAreaRegions = []

        let panel = NSPanel(
            contentViewController: controller
        )
        panel.styleMask = [.titled, .nonactivatingPanel, .fullSizeContentView, .utilityWindow]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        self.hostingController = controller
        self.panel = panel
    }

    func showPanel() {
        guard let button = statusItem.button,
              let buttonWindow = button.window else { return }

        // 确保 SwiftUI 排版到 fitting size(首次显示时 panel 可能还是默认大小)
        hostingController.view.layoutSubtreeIfNeeded()
        let fitting = hostingController.view.fittingSize
        if fitting.width > 0, fitting.height > 0 {
            panel.setContentSize(fitting)
        }

        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRect)
        let panelSize = panel.frame.size

        var x = screenRect.midX - panelSize.width / 2
        let y = screenRect.minY - panelSize.height - 4

        if let screen = buttonWindow.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            x = max(vf.minX + 6, min(x, vf.maxX - panelSize.width - 6))
        }

        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
        refreshClickMonitor()
    }

    func hidePanel() {
        panel.orderOut(nil)
        removeClickMonitor()
    }

    // MARK: - Pin behavior
    // 用 global monitor 而不是 resignKey 检测点外部:nonactivating panel 拿不到稳定的 key 事件。

    private func refreshClickMonitor() {
        removeClickMonitor()
        guard panel.isVisible, !isPinned else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hidePanel() }
        }
    }

    private func removeClickMonitor() {
        if let m = clickMonitor {
            NSEvent.removeMonitor(m)
            clickMonitor = nil
        }
    }

    // MARK: - Icon state

    private func trackIconState() {
        applyCurrentIconState()
        withObservationTracking { [dashboard] in
            _ = dashboard.approvals
            _ = dashboard.hasActiveAutoAllow
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackIconState() }
        }
    }

    private func applyCurrentIconState() {
        let state: MenuBarIconState
        if !dashboard.approvals.isEmpty {
            state = .pending
        } else if dashboard.hasActiveAutoAllow {
            state = .autoAllow
        } else {
            state = .idle
        }
        guard state != lastAppliedIconState else { return }
        lastAppliedIconState = state
        statusItem?.button?.image = MenuBarIconRenderer.image(for: state)
    }

    // MARK: - Main window

    func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: MainSceneID.matches) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - Icon rendering

enum MenuBarIconState { case idle, pending, autoAllow }

/// 菜单栏图标:template image(黑前景 + 透明底),macOS 自动反相。
/// 三态靠形状区分,不能靠颜色 —— template 被 OS 按 alpha 重染。
///   idle       — 纯方框 + 3 线
///   pending    — 右上角实心圆点(需要操作)
///   autoAllow  — 右上角空心圆环(临时信任生效中)
enum MenuBarIconRenderer {
    private static let idleImage: NSImage = render(state: .idle)
    private static let pendingImage: NSImage = render(state: .pending)
    private static let autoAllowImage: NSImage = render(state: .autoAllow)

    static func image(for state: MenuBarIconState) -> NSImage {
        switch state {
        case .idle: return idleImage
        case .pending: return pendingImage
        case .autoAllow: return autoAllowImage
        }
    }

    private static func render(state: MenuBarIconState) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let scale = rect.width / 16.0
            ctx.scaleBy(x: scale, y: scale)

            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setFillColor(NSColor.black.cgColor)

            // Rounded rect outline
            ctx.setLineWidth(1.5)
            let box = CGPath(
                roundedRect: CGRect(x: 1.5, y: 3, width: 11, height: 10),
                cornerWidth: 2.2, cornerHeight: 2.2, transform: nil
            )
            ctx.addPath(box)
            ctx.strokePath()

            // 3 inner lines (decreasing lengths, round caps)
            ctx.setLineWidth(1.2)
            ctx.setLineCap(.round)
            let lineX1: CGFloat = 3.7
            for (y, xEnd) in [(5.8, 8.8), (8.0, 7.5), (10.2, 5.8)] as [(CGFloat, CGFloat)] {
                ctx.move(to: CGPoint(x: lineX1, y: y))
                ctx.addLine(to: CGPoint(x: xEnd, y: y))
            }
            ctx.strokePath()

            // Indicator on top-right outer corner
            let dot = CGRect(x: 10.5, y: 1, width: 4, height: 4)
            switch state {
            case .idle: break
            case .pending: ctx.fillEllipse(in: dot)
            case .autoAllow:
                ctx.setLineWidth(1)
                ctx.strokeEllipse(in: dot)
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}
