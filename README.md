# Tarn

Tarn is a VPN client for configurations you provide. It does not provide servers,
nodes, or subscriptions. You import a subscription or configuration you already
have, and the app routes traffic with it on your device.

- iOS 15 and later
- No account, no analytics, no ads
- Rule-based routing with your own groups and rules

## What this repository contains

- `lib/` — the Flutter client (GPL-3.0, derived from FlClash)
- `ios/` — the iOS platform layer: app shell, Packet Tunnel provider, widget
- `vpn_bridge/` — the Flutter plugin that talks to the tunnel provider
- `plugins/` — in-repo plugin packages used by the client

## iOS kernel

The iOS kernel is maintained in a separate repository and is not part of this
one. Building the app requires a kernel archive at
`libclash/ios/FlClashCore.xcframework/ios-arm64/libclash.a`; the build script
`ios/toolchain/build_kernel.sh` documents the expected inputs and tags.

## Building

    git submodule update --init --recursive
    flutter pub get
    flutter gen-l10n
    flutter build ios --release --no-codesign

## Third-party components

| Component | License |
| --- | --- |
| FlClash | GPL-3.0 |
| Clash.Meta (mihomo) | GPL-3.0 |
| prism_ui | GPL-3.0 |

## Privacy

The app collects no data. See [PRIVACY.md](PRIVACY.md).
