import SwiftUI

@main
struct HyperliquidApp: App {
    @StateObject private var session = AppSession()

    init() {
        WalletConnectService.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(WalletConnectService.shared)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    // Deep-link handler for return-from-wallet.
                    WalletConnectService.shared.handle(url)
                }
        }
    }
}
