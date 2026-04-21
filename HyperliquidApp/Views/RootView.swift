import SwiftUI

struct RootView: View {
    @EnvironmentObject var session: AppSession

    var body: some View {
        TabView(selection: $session.selectedTab) {
            HomeView(api: session.api, socket: session.socket)
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(MainTab.home)

            MarketsView(api: session.api, socket: session.socket)
                .tabItem { Label("Markets", systemImage: "chart.bar.fill") }
                .tag(MainTab.markets)

            TradeView(session: session, api: session.api, socket: session.socket, exchange: session.exchange)
                .tabItem { Label("Trade", systemImage: "arrow.left.arrow.right.square.fill") }
                .tag(MainTab.trade)

            AssetsView(api: session.api, socket: session.socket)
                .tabItem { Label("User", systemImage: "person.crop.circle.fill") }
                .tag(MainTab.assets)
        }
        .tint(.brandUp)
    }
}

#Preview {
    RootView().environmentObject(AppSession())
}
