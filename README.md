# Hyperliquid iOS

A native SwiftUI client for [Hyperliquid](https://hyperliquid.xyz).
Connect a wallet via WalletConnect, browse markets, chart prices, and place
perp orders signed locally by an on-device agent key.

> This is an unofficial community client — not affiliated with, nor endorsed
> by, Hyperliquid Labs.

## Table of contents

- [Features](#features)
- [Screens](#screens)
- [Architecture](#architecture)
- [Getting started](#getting-started)
  - [Prerequisites](#prerequisites)
  - [Clone and configure](#clone-and-configure)
  - [Keep your team ID out of git](#keep-your-team-id-out-of-git-optional)
  - [Generate the Xcode project and build](#generate-the-xcode-project-and-build)
- [Using the app](#using-the-app)
- [Project layout](#project-layout)
- [WebSocket channels used](#websocket-channels-used)
- [Security notes](#security-notes)
- [Contributing](#contributing)
- [License](#license)

## Features

- **Home** — total equity, 24h PnL, quick-tickers, in-place market search.
- **Markets** — All / Crypto / TradFi / HIP-3 filters, Apple-Stocks-style
  rows, Hot / Gainers / Losers / Volume sort tabs, ref-count'd live prices
  over `allMids`.
- **Trade** — symbol picker, K-line (pannable + zoomable, MA 7 / 25 / 99,
  volume histogram, grid, last-price tag), orderbook / depth chart / trades
  tape panels, order form with stepper inputs, size slider with 25 / 50 /
  75 / MAX shortcuts, stacked Open Long / Open Short buttons, full-page
  chart detail view.
- **User** — wallet connect / disconnect, enable / rotate / disable
  trading, account-mode auto-detection (Standard / Unified / Portfolio
  Margin — via the `userAbstraction` REST endpoint, 6h stale-while-
  revalidate cache), per-dex HIP-3 deployer balances + positions,
  testnet / mainnet switch, size-unit preference (USDC ↔ base coin).

## Screens

Four-tab SwiftUI app, all state-driven, dark-mode only.

```
Home             Markets          Trade               User
─────────────    ─────────────    ─────────────       ─────────────
Balance card     Search           Symbol + chart icon Wallet + Disconnect
Quick tickers    Category strip   Price + funding     Enable trading
HIP-3 banner     Sort tabs        Pannable K-line     Agent info (rotate)
Movers list      Dense list       OB / Depth / Trades Per-dex HIP-3
                                  Order form          Preferences
                                  Positions / Orders  Network + About
                                  TWAP / Fills …
```

## Architecture

### Signing

All Hyperliquid signing happens locally.

- **User-signed actions** (`approveAgent`, `withdraw3`, `usdSend`,
  `usdClassTransfer`) are EIP-712 typed-data signed by the connected wallet
  through `eth_signTypedData_v4`. The transport chain is picked dynamically
  from the session's negotiated namespace (Arbitrum Sepolia > Arbitrum One
  > any `eip155:*`) so the wallet doesn't reject with "invalid permissions
  for call".
- **L1 actions** (`order`, `cancel`, `updateLeverage`, …) are signed by a
  secp256k1 agent key generated on-device. The 32-byte private scalar lives
  in the iOS Keychain behind `SecAccessControlCreateWithFlags` with
  `.userPresence` — every read prompts FaceID or device passcode.
  `LAContext.touchIDAuthenticationAllowableReuseDuration = 300` keeps the
  UX reasonable by suppressing re-prompts within a 5-minute window.
- `MsgPack.swift` is a hand-rolled msgpack encoder whose output matches
  Python's `msgpack.packb` byte-for-byte — a requirement for Hyperliquid's
  `action_hash` construction.
- `secp256k1_context_randomize` is called once at context creation to
  blind the sign routine against side-channel leakage.

### WebSocket

- Auto-reconnect with exponential backoff + ±25 % jitter and a 90s
  no-traffic watchdog.
- Subscription refcount + multi-handler. Multiple viewmodels can subscribe
  the same channel without spamming the server — the first call hits the
  wire, subsequent calls bump a counter and attach a token-keyed handler.
- Late-subscriber replay. The last payload seen on each channel is cached
  and replayed synchronously to any handler that registers afterwards, so
  a tab that mounts late (e.g. Trade after Home) gets data this tick
  instead of waiting for the next server emit.
- Uses the dex-aggregated `allDexsClearinghouseState`, `allDexsAssetCtxs`,
  and `spotState` channels so HIP-3 venues surface alongside core without
  N separate subscriptions. Per-dex `openOrders` still has to be
  subscribed once per dex (there's no `allDexsOpenOrders`).

### Data model

- `UserState` decodes permissively — per the docs the WS delivers
  `clearinghouseStates` as `Record<string, ClearinghouseState>`, but
  in practice it's an array of `[dex, state]` tuples. The custom
  `Decodable` attempts both shapes. Fields tolerate number or
  string-numeric values (REST uses strings, WS uses numbers for the
  same keys). `marginSummary` falls back to `crossMarginSummary` when
  absent (common on unified accounts).
- Account mode is auto-detected via the `userAbstraction` info endpoint
  on the current wallet address. Result is cached in `UserDefaults`
  keyed by env + address for 6 hours with stale-while-revalidate
  semantics so repeat launches don't re-hit REST.

## Getting started

### Prerequisites

- macOS 14 (Sonoma) or newer
- Xcode 15.3+ (iOS 17 SDK)
- [xcodegen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`
- A Reown / WalletConnect project id — create one free at
  <https://cloud.reown.com>
- An Apple Developer team for signing. A free personal team is enough for
  simulator builds. Device builds need a paid team so the
  `com.apple.security.application-groups` entitlement (`group.exchange.mtf.hl`,
  used by Reown's session storage) can be provisioned.

### Clone and configure

```bash
git clone git@github.com:mtf-exchange/hyperliquid-ios.git
cd hyperliquid-ios
```

Edit `project.yml`:

```yaml
settings:
  base:
    DEVELOPMENT_TEAM: "YOUR_TEAM_ID"     # e.g. ABCDE12345
...
targets:
  HyperliquidApp:
    info:
      path: HyperliquidApp/Resources/Info.plist
      properties:
        REOWN_PROJECT_ID: "your-reown-project-id"
```

Both fields also appear in `HyperliquidApp/Resources/Info.plist` after the
first `xcodegen generate`; updating `project.yml` is the source of truth —
the plist will be rewritten on each regeneration.

### Keep your team ID out of git (optional)

If you'd rather not commit your team ID, create a git-ignored xcconfig:

```bash
cat > Local.xcconfig <<'EOF'
DEVELOPMENT_TEAM = YOUR_TEAM_ID
EOF
echo 'Local.xcconfig' >> .gitignore
```

Then in `project.yml`:

```yaml
configFiles:
  Debug: Local.xcconfig
  Release: Local.xcconfig
settings:
  base:
    DEVELOPMENT_TEAM: ""   # overridden by the xcconfig
```

### Generate the Xcode project and build

```bash
xcodegen generate
open HyperliquidApp.xcodeproj
```

Then `Cmd-R` to run on the iOS 17+ simulator or a connected device. The
first launch may take a minute while Swift Package Manager resolves
dependencies (Reown, CryptoSwift, secp256k1.swift, SVGView).

## Using the app

1. **Connect a wallet.** Go to the **User** tab → *Connect Wallet* →
   pick MetaMask / Rainbow / Trust / Zerion / Safe / Ledger Live /
   Rainbow-WC / any other WalletConnect v2 wallet. The app will deep-link
   to your wallet, you approve the session, and you're returned to the
   app with a populated address.

   If you just want to browse read-only, tap *Or enter address manually*
   and paste any `0x…` address.

2. **Enable trading.** Still on the User tab → *Enable trading*. The app
   generates a fresh secp256k1 agent key on device, constructs the
   Hyperliquid `approveAgent` EIP-712 typed data, and asks your wallet
   to sign it via WalletConnect. On success, the agent private key is
   saved to the Keychain behind FaceID / passcode, and the app can sign
   orders / cancels / leverage updates locally without a wallet round-trip.

3. **Trade.** Jump to the **Trade** tab. Pick a symbol from the top chip,
   tap a price in the orderbook to auto-fill, adjust size via the stepper
   or the percent slider, tap *Open Long* or *Open Short*. Biometric
   prompt the first time after the reuse window lapses.

4. **Manage positions.** The Positions row on Trade shows every open
   position across core + HIP-3 dexes; tap *Close* to pre-fill a reduce-
   only market order against that position.

5. **Rotate agent.** After 60 days the User tab suggests rotating. One
   tap fires a fresh `approveAgent` flow; the old agent key is wiped
   from the Keychain.

6. **Disconnect.** *Disconnect* on the User tab ends the WalletConnect
   session, clears the cached address, and forgets the agent key.

## Project layout

```
HyperliquidApp/
├── App/                AppSession, TradingEnabler, app entry
├── Models/             Market, OrderBook, Candle, UserState, Spot, History
├── Networking/         HyperliquidAPI (/info), HyperliquidSocket (WS),
│                       HyperliquidExchangeAPI (/exchange),
│                       WalletConnectService
├── Signing/            AgentKey (secp256k1 + Keychain), MsgPack,
│                       ActionHasher, L1Signer, EIP712, order / transfer
│                       action builders, Secp256k1Raw
├── ViewModels/         Home / Markets / MarketDetail / Trade /
│                       TradeTab (activity) / Assets / Portfolio / History
├── Views/              RootView (TabView), Home, Markets, Trade,
│                       ChartDetail (full-page K-line), Assets (User tab),
│                       KLineChartView, DepthLadder, CoinLogo, Transfer
├── Utilities/          Formatters (Hyperliquid-style 5-sig-fig prices,
│                       brand colours, delta helpers)
└── Resources/          Assets.xcassets, Info.plist
```

## WebSocket channels used

| Channel                       | Purpose                                               |
|-------------------------------|-------------------------------------------------------|
| `allMids`                     | Live mark prices for every asset                      |
| `l2Book`                      | Orderbook for the currently viewed symbol             |
| `trades`                      | Recent trades tape                                    |
| `candle`                      | In-flight candle for the active interval              |
| `activeAssetCtx`              | Per-symbol open interest / funding / mark             |
| `allDexsClearinghouseState`   | Core + every HIP-3 dex's positions + margin           |
| `allDexsAssetCtxs`            | Cross-dex perp contexts                               |
| `spotState`                   | Live spot balances (replaces REST `spotClearinghouseState`) |
| `openOrders`                  | Per-dex open order book; one subscription per dex     |
| `orderUpdates`                | Per-order open / filled / cancelled deltas            |
| `userFills` / `userFundings`  | Fill + funding history                                |

## Security notes

- The main-wallet private key never touches this app — WalletConnect
  delegates signing to the wallet that holds it.
- The local agent key can only place orders / cancel / update leverage;
  it cannot withdraw, transfer, or approve further agents.
- The agent key is stored behind a biometric / passcode access-control
  object with `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`. Device
  without a passcode ⇒ Enable trading fails loudly instead of falling
  back to unprotected storage.
- Agent keys are suggested for rotation after 60 days. Rotate by tapping
  *Rotate agent* in the User tab — wipes the old key and runs a fresh
  `approveAgent`.
- The WS stack doesn't do certificate pinning today. If you're deploying
  to hostile networks, add a `URLSessionDelegate` with SPKI pinning
  against `api.hyperliquid.xyz`.

## Contributing

Issues and pull requests welcome. Keep in mind:

- Don't add dependencies without a strong reason — the app deliberately
  hand-rolls msgpack, EIP-712, and secp256k1 plumbing instead of pulling
  in a wallet SDK.
- All WS-touching code should go through the existing `HyperliquidSocket`
  refcount / multi-handler / replay machinery — don't open ad-hoc sockets.
- For new screens, match the app's brand palette (`Color.brandUp`,
  `Color.brandDown`, `Color.delta(_:)`) and dynamic price formatter
  (`Formatters.price`, 5-sig-fig Hyperliquid rule).
- Run `xcodegen generate` after changes to `project.yml`.

## License

MIT. See [`LICENSE`](./LICENSE).
