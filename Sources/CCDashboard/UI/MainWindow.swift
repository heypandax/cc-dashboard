import SwiftUI

struct MainWindow: View {
    let dashboard: Dashboard
    @State private var selectedSession: SessionState.ID?

    /// 走 LocalizedStringKey 而非 interpolated String 是为了让 SwiftUI 把
    /// "CC Dashboard · %lld pending" 当成可本地化的 key(走 Bundle.main lookup)。
    private var titleKey: LocalizedStringKey {
        let n = dashboard.approvals.count
        return n == 0 ? "CC Dashboard" : "CC Dashboard · \(n) pending"
    }

    var body: some View {
        NavigationSplitView {
            SessionListView(dashboard: dashboard, selection: $selectedSession)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 400)
        } detail: {
            ApprovalQueueView(dashboard: dashboard)
        }
        .navigationTitle(titleKey)
        .frame(minWidth: 800, minHeight: 520)
    }
}
