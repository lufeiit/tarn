import hashlib
import pathlib
import plistlib
import subprocess
import sys

APP_ID = "com.tarn.app"
EXTENSIONS = {
    "com.tarn.app.PacketTunnel": "PlugIns/PacketTunnel.appex",
    "com.tarn.app.VpnWidget": "PlugIns/VpnWidget.appex",
}
APP = pathlib.Path("build/ios/iphoneos/Runner.app")
ABOUT_ICON = "ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png"
ABOUT_ICON_SHA256 = "a2041b4b814ea6d65e26dc02f5adc640d07b5f14d143464fe5284ffc9b9d5b73"


def check(condition, message):
    if not condition:
        raise SystemExit("ASSERT FAILED: " + message)
    print("ok:", message)


def plist(path):
    return plistlib.loads(path.read_bytes())


def entitlements(bundle):
    result = subprocess.run(
        ["codesign", "-d", "--entitlements", ":-", str(bundle)],
        check=True, capture_output=True,
    )
    data = result.stdout + result.stderr
    start = data.index(b"<?xml")
    end = data.rindex(b"</plist>") + len(b"</plist>")
    return plistlib.loads(data[start:end])


def main():
    global APP
    mode = sys.argv[1] if len(sys.argv) > 1 else "pre"
    if len(sys.argv) > 2:
        APP = pathlib.Path(sys.argv[2])
    check(APP.is_dir(), "Runner.app exists")
    info = plist(APP / "Info.plist")
    check(info["CFBundleIdentifier"] == APP_ID, f"bundle id is {APP_ID}")
    check(info["CFBundleDisplayName"] == "Tarn", "display name is Tarn")
    schemes = {scheme for entry in info.get("CFBundleURLTypes", []) for scheme in entry.get("CFBundleURLSchemes", [])}
    check(schemes == {"tarn"}, "distribution registers only tarn")
    check(bool(info.get("NSCameraUsageDescription")), "camera purpose string present")
    check(bool(info.get("NSPhotoLibraryUsageDescription")), "photo library purpose string present")
    check((APP / "PrivacyInfo.xcprivacy").exists(), "privacy manifest bundled")
    icon = APP / "Assets.car"
    check(icon.exists(), "asset catalog bundled")
    about_icon = APP / "Frameworks/App.framework/flutter_assets" / ABOUT_ICON
    check(about_icon.is_file(), "Flutter About icon bundled")
    check(hashlib.sha256(about_icon.read_bytes()).hexdigest() == ABOUT_ICON_SHA256,
          "Flutter About icon matches approved artwork")

    version = info["CFBundleVersion"]
    for bundle_id, relative in EXTENSIONS.items():
        bundle = APP / relative
        sub = plist(bundle / "Info.plist")
        check(sub["CFBundleIdentifier"] == bundle_id, f"{bundle_id} bundle id")
        check(sub["CFBundleVersion"] == version, f"{bundle_id} build number matches")


    if mode == "post":
        for bundle_id, relative in EXTENSIONS.items():
            bundle = APP / relative
            ent = entitlements(bundle)
            check("com.apple.security.application-groups" in ent, f"{bundle_id} has app group")
            if bundle_id.endswith(".VpnWidget"):
                check(
                    "com.apple.developer.networking.networkextension" not in ent,
                    f"{bundle_id} has no network extension entitlement",
                )
            else:
                check(
                    ent.get("com.apple.developer.networking.networkextension") == ["packet-tunnel-provider"],
                    f"{bundle_id} network extension entitlement",
                )
            check((bundle / "embedded.mobileprovision").exists(), f"{bundle_id} profile embedded")
            check(ent.get("get-task-allow") is False, f"{bundle_id} is a distribution build")
        ent = entitlements(APP)
        check("com.apple.security.application-groups" in ent, "app has app group")
        check(
            ent.get("com.apple.developer.networking.networkextension") == ["packet-tunnel-provider"],
            "app network extension entitlement",
        )
        check((APP / "embedded.mobileprovision").exists(), "app profile embedded")
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(APP)], check=True)
        print("ok: signature verifies")


if __name__ == "__main__":
    main()
