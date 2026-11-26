# FlowArc — App Store Connect copy

## Beta App Description

FlowArc is a general-purpose VPN client for iOS. Import a configuration or create your own, choose a route, and view network activity on your device. FlowArc does not include VPN servers and does not sell VPN subscriptions.

## What to Test

On first launch, read and acknowledge the VPN Privacy Notice. Verify that no VPN connection is started. Import a profile in **Profiles** using a configuration URL or local YAML file, or create a configuration. Select it, return to the dashboard, and tap the VPN switch. If prompted, allow iOS to add the VPN configuration. Check that a webpage loads in Safari, then disconnect. The privacy notice can be opened again from **Tools**.

## Beta App Review / App Review Notes

No FlowArc account, login, or purchase is required. The app does not include preset VPN servers. Use the following configuration for review only:

Review configuration URL: https://flowarc.sub-you.top/review-9c41a7.yaml

1. Open FlowArc and tap **Got it** on the **VPN Privacy Notice**. The VPN stays off.
2. Open **Profiles**, choose **Add profile**, and import the review configuration using the URL above. Select the imported profile.
3. Return to the dashboard and turn on **VPN**. Tap **Allow** if iOS asks for permission to add a VPN configuration. The review profile has one endpoint, **Review VPN**, selected by default in **Review Route**.
4. Open `https://example.com` in Safari and verify it loads. For an additional check, compare your public IP before and after connecting. Return to the dashboard and turn off the VPN when finished.
5. The VPN data-flow disclosure can also be found under **Tools → VPN Privacy Notice**.

The review configuration uses a temporary Shadowsocks endpoint reachable at the URL above. It is a temporary test resource; it is not bundled with the app or offered to users as a service. For technical questions, contact Xie Yunke at sp-flowarc@outlook.com / +12677020497.
