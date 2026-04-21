import SwiftUI
import SVGView

/// Renders a Hyperliquid coin logo by fetching the SVG from
/// `https://app.hyperliquid.xyz/coins/{symbol}.svg`. Symbols may contain
/// reserved chars (e.g. `xyz:CL`) so we URL-encode them. SVG bytes are
/// cached in-memory across views.
struct CoinLogo: View {
    let symbol: String
    var size: CGFloat = 28

    @State private var data: Data?
    @State private var failed: Bool = false

    var body: some View {
        ZStack {
            Circle().fill(Color.gray.opacity(0.15))
            if let data {
                SVGView(data: data)
                    .frame(width: size * 0.78, height: size * 0.78)
            } else if failed {
                Text(String(symbol.prefix(2)))
                    .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .task(id: symbol) { await load() }
    }

    private func load() async {
        if let cached = LogoCache.shared.get(symbol) {
            data = cached
            return
        }
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        guard let url = URL(string: "https://app.hyperliquid.xyz/coins/\(encoded).svg") else {
            failed = true
            return
        }
        do {
            let (raw, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("svg") else {
                failed = true
                return
            }
            LogoCache.shared.set(symbol, raw)
            data = raw
        } catch {
            failed = true
        }
    }
}

private final class LogoCache {
    static let shared = LogoCache()
    private let cache = NSCache<NSString, NSData>()

    init() { cache.countLimit = 200 }

    func get(_ key: String) -> Data? { cache.object(forKey: key as NSString) as Data? }
    func set(_ key: String, _ data: Data) { cache.setObject(data as NSData, forKey: key as NSString) }
}
