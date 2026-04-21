# Hyperliquid iOS

A native SwiftUI client for [Hyperliquid](https://hyperliquid.xyz). Connect a
wallet via WalletConnect, browse markets, chart prices, and place perp orders
signed locally by an on-device agent key.

> This is an unofficial community client — not affiliated with, nor endorsed
> by, Hyperliquid Labs.

## Features

- **Home** — total equity, 24h PnL, quick-tickers, in-place market search.
- **Markets** — Crypto / TradFi / HIP-3 filters, Apple-Stocks-style rows.
- **Trade** — symbol picker, K-line (pannable / zoomable, MA7/25/99, volume),
  orderbook / depth chart / trades-tape panels, order form with stepper
  inputs, size slider, Open Long / Open Short buttons.
- **User** — wallet connect + disconnect, enable / rotate / disable trading,
  account-mode detection (`userAbstraction` endpoint, 6h stale-while-
  revalidate cache), HIP-3 deployer balances, per-device size-unit preference
  (USDC ↔ base coin), testnet / mainnet switch.

### Signing

All Hyperliquid signing is done locally.

- **User-signed actions** (`approveAgent`, `withdraw3`, `usdSend`,
  `usdClassTransfer`) are EIP-712 typed-data signed by the connected wallet
  through `eth_signTypedData_v4`.
- **L1 actions** (`order`, `cancel`, `updateLeverage`, …) are signed by a
  secp256k1 agent key generated on-device and kept in the Keychain behind
  `kSecAttrAccessControl` with `.userPresence` (FaceID / passcode).
- `MsgPack.swift` is a hand-rolled msgpack encoder whose output matches
  Python's `msgpack.packb` byte-for-byte — a requirement for Hyperliquid's
  `action_hash` construction.

### WebSocket

- Auto-reconnect with exponential backoff + jitter and a 90s no-traffic
  watchdog.
- Subscription refcount + multi-handler (multiple viewmodels can subscribe
  the same channel without spamming the server).
- Late-subscriber replay: the last payload on each channel is cached so a
  view that mounts late (e.g. Trade tab after Home) gets data instantly.
- Uses the dex-aggregated `allDexsClearinghouseState`, `allDexsAssetCtxs`,
  and `spotState` channels so HIP-3 venues surface alongside core.

## Requirements

- Xcode 15.3 or newer (iOS 17 SDK)
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- A Reown / WalletConnect project id from <https://cloud.reown.com>
- An Apple Developer team to sign the build (free personal team works on
  simulator; device builds need a paid team for the App Groups entitlement
  the WalletConnect session storage uses).

## Build

```bash
brew install xcodegen              # one-time
# 1) Put your Reown project id in project.yml + Info.plist (both places
#    have a REOWN_PROJECT_ID field with an empty placeholder)
# 2) Set DEVELOPMENT_TEAM in project.yml (or via a Local.xcconfig you
#    gitignore)
xcodegen generate
open HyperliquidApp.xcodeproj
```

## Layout

```
HyperliquidApp/
├── App/                AppSession, TradingEnabler, app entry
├── Models/             Market, OrderBook, Candle, UserState, Spot, History
├── Networking/         HyperliquidAPI (/info), HyperliquidSocket (WS),
│                       HyperliquidExchangeAPI (/exchange),
│                       WalletConnectService
├── Signing/            AgentKey (secp256k1 + Keychain), MsgPack,
│                       ActionHasher, L1Signer, EIP712, order/transfer
│                       action builders
├── ViewModels/         Home / Markets / MarketDetail / Trade /
│                       TradeTab (activity) / Assets / Portfolio / History
├── Views/              RootView (TabView), Home, Markets, Trade,
│                       ChartDetail (full-page K-line), Assets (User tab)
├── Utilities/          Formatters (dynamic-precision price, brand colours)
└── Resources/          Assets.xcassets, Info.plist
```

## References

- Hyperliquid docs — <https://hyperliquid.gitbook.io/hyperliquid-docs>
- Python SDK (signing spec source of truth) —
  <https://github.com/hyperliquid-dex/hyperliquid-python-sdk>
- Reown Swift (WalletConnect) —
  <https://github.com/reown-com/reown-swift>

## License

MIT. See `LICENSE`.
