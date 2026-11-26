#!/usr/bin/env bash
# ============================================================================
# iOS 内核（libclash.a / c-archive）构建脚本 —— 固定配方 + CPU 特性 overlay 补丁
#
# 用法（在 Mac 上，仓库根目录 ~/FlClash）：
#   bash ios/toolchain/build_kernel.sh
#
# 相比手敲命令，这里多了两样东西，都不能省：
#   1. -overlay=<json>：把 Go 标准库 internal/cpu/cpu_arm64_other.go 替换为
#      ios/toolchain/cpu_arm64_other.go，补上 iOS 上缺失的 arm64 CPU 特性检测
#      （否则 AES-256-GCM 全程走软件实现，实测吃掉约一半 CPU）。详见 README.md。
#   2. 构建后自检：产物大小与 gvisor 引用数，防"漏 tag 导致 TUN 必死"的老坑。
# ============================================================================
set -euo pipefail

export PATH=/opt/homebrew/bin:${PATH:-/usr/bin:/bin}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_REPO="$(cd "$HERE/../.." && pwd)"
CORE="${IOS_KERNEL_DIR:-$APP_REPO/ios-kernel}"
[ -d "$CORE" ] || CORE="$APP_REPO/core"
OUT="$APP_REPO/libclash/ios/FlClashCore.xcframework/ios-arm64/libclash.a"
PATCH="$HERE/cpu_arm64_other.go"

[ -d "$CORE" ] || { echo "找不到内核目录: $CORE" >&2; exit 9; }
[ -f "$PATCH" ] || { echo "找不到 overlay 补丁: $PATCH" >&2; exit 9; }

# ---- 组装 overlay 映射（stdout 里不留生成物；json 放固定路径，便于复现/排查）----
GOROOT="$(go env GOROOT)"
STDLIB_FILE="$GOROOT/src/internal/cpu/cpu_arm64_other.go"
[ -f "$STDLIB_FILE" ] || { echo "标准库文件不存在（Go 版本变了？）: $STDLIB_FILE" >&2; exit 9; }

# 补丁必须真的改了 osInit，否则构建"成功"但没有效果
if ! grep -q "ARM64.HasAES = true" "$PATCH"; then
  echo "overlay 补丁内容异常（未设置 ARM64.HasAES）: $PATCH" >&2; exit 9
fi

OVL="/tmp/flclash-ios-overlay.json"
cat > "$OVL" <<JSON
{"Replace": {"$STDLIB_FILE": "$PATCH"}}
JSON

echo "== 构建 iOS 内核 =="
echo "  GOROOT   : $GOROOT"
echo "  overlay  : $OVL"
echo "  replace  : $STDLIB_FILE"
echo "           → $PATCH"
echo "  产物     : $OUT"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CC_CMD="$(xcrun -f clang) -arch arm64 -isysroot $SDK"

# 诊断层开关（2026-09-19）：ios-release 分支的分层 —— 带 ios_diag 才会启动
# 采样器/落 extDiag/抓 CPU profile；正式版（TestFlight/App Store）不要带。
TAGS="with_gvisor,with_low_memory"
# 测试线默认带诊断层（2026-09-19）：直接调用本脚本时也保留诊断；正式线上的该默认值
# 为 0（由 build-ios-local.sh 按分支传入 IOS_DIAG 时以显式值为准）。
if [ "${IOS_DIAG:-1}" = "1" ]; then
  TAGS="$TAGS,ios_diag"
  echo "  诊断层     : 打开（ios_diag）"
else
  echo "  诊断层     : 关闭（正式版：零诊断落盘 / 不起采样循环）"
fi
# ---- xcframework 骨架自愈（2026-10-07）：/libclash/ 被 gitignore ⇒ CI 全新克隆里
# 没有 .xcframework 目录，xcodebuild 会报 "There is no Info.plist found at
# .../FlClashCore.xcframework/Info.plist"。开发机已有完整骨架时此处为 no-op。
XCF_DIR="$(dirname "$OUT")"
if [ ! -f "$XCF_DIR/../Info.plist" ]; then
  mkdir -p "$XCF_DIR"
  cat > "$XCF_DIR/../Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
        <key>AvailableLibraries</key>
        <array>
                <dict>
                        <key>BinaryPath</key>
                        <string>libclash.a</string>
                        <key>LibraryIdentifier</key>
                        <string>ios-arm64</string>
                        <key>LibraryPath</key>
                        <string>libclash.a</string>
                        <key>SupportedArchitectures</key>
                        <array>
                                <string>arm64</string>
                        </array>
                        <key>SupportedPlatform</key>
                        <string>ios</string>
                </dict>
        </array>
        <key>CFBundlePackageType</key>
        <string>XFWK</string>
        <key>XCFrameworkFormatVersion</key>
        <string>1.0</string>
</dict>
</plist>
PLIST
  echo "  xcframework 骨架: 已补建 Info.plist（首次/CI 环境）"
else
  echo "  xcframework 骨架: 已存在（开发机，跳过）"
fi

cd "$CORE"
# 先删旧产物（2026-09-23）：否则构建失败时旧 libclash.a 仍留在原处，xcodebuild 会
# 静默复用它（ios/toolchain/README.md 记录过「内核没重编，xcodebuild 只花 15s 就成功」）。
# 删掉后失败即「无产物」，构建期的错误会立刻暴露，而不是延迟到真机。
rm -f "$OUT"

# garble 实验开关（防逆向 P2，2026-10-24）：USE_GARBLE=1 时用 garble 编译内核
#（符号名混淆；不带 -literals ⇒ 字符串字面量不加密，lfexp-sing-tun-v1 自证哨兵
# 仍然可 grep）。
# ⚠️ 实验性，默认关。上正式线前必须验证：
#   1. //export 的 C 符号（quickSetup/startTUN/setTunBufKB/...）在 c-archive 里
#      名字不变（ClashCoreBridge.swift 的 @_silgen_name 依赖它们）；
#   2. -overlay 透传正常（CPU 特性补丁仍生效，真机 [cpu-feat] aes=true）；
#   3. 真机回归：隧道通、Speedtest 正常、[mem-breakdown] 无异常。
# 本地验证过的部分：翻转构建（darwin+cgo）下 garble 对本包全量编译通过。
if [ "${USE_GARBLE:-0}" = "1" ]; then
  command -v garble >/dev/null 2>&1 || {
    echo "USE_GARBLE=1 但 garble 不在 PATH（go install mvdan.cc/garble@latest）" >&2
    exit 8
  }
  echo "  garble    : $(garble version 2>/dev/null | head -1 || echo unknown)（实验：符号混淆，字符串不加密）"
  BUILD_CMD=(garble -tiny build)
else
  BUILD_CMD=(go build)
fi

CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
  CFLAGS="-O2" \
  CC="$CC_CMD" \
  "${BUILD_CMD[@]}" -overlay="$OVL" -ldflags="-w -s -buildid=" \
  -tags="$TAGS" \
  -buildmode=c-archive -o "$OUT" .

# ---- 产物自检 ----
# 非 garble：大小 ≈64.9MB、gvisor 引用 ≈6700（漏了 with_gvisor ⇒ 45.8MB/≈4，
# gvisor 计数主要来自符号名）。garble 混淆符号名 ⇒ gvisor 计数失效，改验
# 字符串自证哨兵（不带 -literals ⇒ 协议/补丁串仍在）+ 大小下限。
SIZE_BYTES=$(stat -f%z "$OUT")
SIZE_MB=$(awk -v b="$SIZE_BYTES" 'BEGIN{printf "%.1f", b/1048576}')
echo "== 自检 =="
printf "  大小      : %s MB\n" "$SIZE_MB"
if [ "${USE_GARBLE:-0}" = "1" ]; then
  SENTINEL=$(strings -a "$OUT" | grep -c "lfexp-sing-tun-v1" || true)
  printf "  补丁自证  : %s（lfexp-sing-tun-v1）\n" "$SENTINEL"
  if [ "$SIZE_BYTES" -lt 60000000 ] || [ "$SENTINEL" -lt 1 ]; then
    echo "  ✗ 产物异常：疑似漏了 with_gvisor tag 或补丁哨兵丢失" >&2
    exit 1
  fi
else
  GV=$(strings -a "$OUT" | grep -ci gvisor || true)
  printf "  gvisor 引用: %s\n" "$GV"
  if [ "$SIZE_BYTES" -lt 60000000 ] || [ "$GV" -lt 1000 ]; then
    echo "  ✗ 产物异常：疑似漏了 with_gvisor tag（该栈是 iOS TUN 的唯一可用栈）" >&2
    exit 1
  fi
fi
echo "  ✓ 产物正常"
echo
echo "提示：硬件 AES 是否真正生效，以真机日志 [cpu-feat] 行的 **aesctr 读数与 AES 硬件/软件判定** 为准。"
