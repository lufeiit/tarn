# Tarn

Tarn is a VPN client for configurations you provide. It does not provide servers,
nodes, or subscriptions. You import a subscription or configuration you already
have, and the app routes traffic with it on your device.

- iOS 15 and later
- No account, no analytics, no ads
- Rule-based routing with your own groups and rules

## Source and license

This repository is the client application and its iOS platform layer, released
under the GNU General Public License v3.0. See [LICENSE](LICENSE).

## Building

    git submodule update --init --recursive
    flutter pub get
    flutter gen-l10n
    bash ios/toolchain/build_kernel.sh
    flutter build ios --release --no-codesign

## Third-party components

| Component | License |
| --- | --- |
| FlClash | GPL-3.0 |
| Clash.Meta (mihomo) | GPL-3.0 |
| prism_ui | GPL-3.0 |

## Privacy

The app collects no data. See [PRIVACY.md](PRIVACY.md).
