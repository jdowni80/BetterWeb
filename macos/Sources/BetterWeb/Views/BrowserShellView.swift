import SwiftUI

struct BrowserShellView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            if !model.sidebarCollapsed {
                VerticalTabsView()
                    .transition(.move(edge: .leading))
            }

            VStack(spacing: 0) {
                TopBarView()
                    .zIndex(10)
                ContentAreaView()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeOut(duration: 0.18), value: model.sidebarCollapsed)
        .background(ApheleiaTheme.bgPrimary)
        .background(WindowAccessor(sidebarCollapsed: model.sidebarCollapsed))
        .ignoresSafeArea()
        .onAppear { model.start() }
    }
}
