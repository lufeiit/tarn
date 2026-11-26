# ios/toolchain —— iOS 内核构建工具链

## 文件

| 文件 | 作用 |
|---|---|
| `build_kernel.sh` | 构建 iOS 内核 `libclash.a`（固定配方 + overlay 补丁 + 产物自检）。**出包前必须先跑它**。 |
| `cpu_arm64_other.go` | Go 标准库 `src/internal/cpu/cpu_arm64_other.go` 的补丁副本，通过 `-overlay` 替换原文件参与编译。 |
| `README.md` | 本文件。 |

Flutter / Xcode 构建成功不等于 Go 内核已更新：`PacketTunnel` 链接的是 `libclash/ios/FlClashCore.xcframework` 里的预编译静态库。改过 `core/` 后先单独运行 `build_kernel.sh`，确认归档已更新，再签名装机。LFExp 测速若仍被内存闸门拦截，先核对新一轮扩展日志的 `floor=`；未设置设备覆盖时，iOS 应为 `8192KB`，不是桌面的 `65536KB`。

LFExp v3 从冷启动首次会话直接使用，不等待节点声明、不回退到 v1/v2。装机前确认待测节点支持 v3；规则源备用地址独立由 `rule-providers` 的 `mirrors` 处理。

排查「同节点时通时不通」时，不要把 URL-test 最外层的 `context deadline exceeded` 都归为测速站超时。2026-11-24 真机在 Apple 204 URL 仍复现；内存准入无拒绝，同一节点重复测有成功有失败，同一扩展进程同时捕获了 REALITY 实际证书名称与本次 SNI 不符。先按同一订阅、同一入口、同一测试地址比较桌面与 iOS 的新会话，再对齐客户端握手和入口／节点日志；不要通过关闭证书校验来验证。

## 为什么需要 overlay 补丁（一句话）

**Go 在 iOS 上不做任何 arm64 CPU 特性检测**（`cpu_arm64_other.go` 的 `osInit()` 是空函数），
于是 `ARM64.HasAES=false`、`HasPMULL=false` ⇒ `crypto/aes` 走软件 `encryptBlockGeneric`、
GCM 的 GHASH 走软件 `ghashMul`。而 lfexp 的载荷加密正是 **AES-256-GCM**，
实测这部分吃掉 **约一半 CPU**：

```
# 2026-09-12 真机 [cpu-feat] 自证（未打补丁）
[cpu-feat] arm64 feat: aes=false pmull=false sha1=false sha2=false crc32=false atomics=false | aesgcm256=22MB/s

# 272Mbps 负载 20s CPU profile（总 287% CPU）归因
ghashMul                28.6%
ghash-range1             4.6%
aes.encryptBlockGeneric 15.9%
------------------------------
合计                    49.1%   ← 全是软件 AES-GCM
```

根因不是"CPU 不支持"，而是 **Go 的 build tag 划分问题**：上游 `cpu_arm64_darwin.go`
的 tag 是 `arm64 && darwin && !ios`，且那段代码本来就**硬编码**
`ARM64.HasAES/PMULL/SHA1/SHA2 = true`（上游注释原话：
*Assume the CPU features that Apple Silicon M1 supports to be available on all
future iterations*）。iOS 只是拿不到这段逻辑，与 CPU 能力无关。

## 为什么不能改用 GODEBUG（两条路都堵死，已实测）

| 思路 | 结果 |
|---|---|
| 编译期 `//go:debug cpu.aes=on` | ✗ **编译失败**：`invalid //go:debug: unknown //go:debug setting "cpu.aes"`（该机制只认 `internal/godebugs` 注册项） |
| `NEPacketTunnelProvider.init()` / `startTunnel()` 里 `setenv("GODEBUG", "cpu.aes=on,...")` | ✗ **实测无效**：`internal/cpu` 的选项在 Go runtime 初始化时解析并快照，而扩展进程由 dyld 加载即完成 runtime 初始化，比 `init()` 还早（这也是既有代码必须把 `dir.path` 显式传给 Go、而不能依赖 `os.Getenv` 的原因）；真机 `[cpu-feat]` 仍显示 `aes=false` |
| 运行时 `//go:linkname` 翻转 `crypto/internal/fips140/aes.supportsAES` / `.../gcm.supportsAESGCM` | ✗ **有正确性风险**：本机实验证实，翻转前用 generic 展开的 key schedule 再走 asm 路径会**产生错误密文**（旧 block + asm ≠ 正确结果）。无法保证"翻转前不存在 AES block"，故放弃 |
| `-overlay` 补齐 `osInit()` | ✅ **采用**：特性在程序最开始就是 true，不存在"翻转前"的 block，零运行时风险 |

## 验证方法（必须做）

1. 构建：`bash ios/toolchain/build_kernel.sh`（自检会挡住漏 `with_gvisor` 的坑）
2. 出包 + 装真机（见 `docs/ios-kernel-build.md`）
3. 触发一次短会话（启动隧道即可，内核 `init()` 会打诊断），取 `Library/extDiag.txt`：

```bash
grep -a "cpu-feat" extDiag.txt | tail -1
```

期望（打补丁后）：

```
[cpu-feat] x/sys/cpu(...): aes=false ... | aesctr=4287MB/s aesgcm256=1153MB/s => AES 硬件实现
```

- **只看 `aesctr` 与末尾的「硬件/软件」判定**：软件 CTR AES-256 上限约 200~300MB/s，
  硬件 3~5GB/s（实测 4287MB/s 量级），差 10 倍以上。
- ⚠️ **坑 1：不要拿 `golang.org/x/sys/cpu` 的 `aes=false` 当依据**。那个包有一套
  **自己独立的**检测（在本项目里同样不认 iOS），与真正决定 crypto 走哪条路的
  **标准库 `internal/cpu`** 是两回事；overlay 生效时它照样打印 `aes=false`
  —— 踩过这个坑，误报了一次告警。
- ⚠️ **坑 2：不要用 AES-GCM `Seal(nil, …)` 做微基准**。它每次都分配输出缓冲，
  在高负载进程里量到的基本是 GC 而非 AES —— 同一内核三次读数
  22 / 219 / 1153 MB/s，阈值判定必然误报。现改用零分配的 CTR 批量吞吐（max-of-3）。
- 判定为「软件实现」时，内核自己会打 `*** AES 走的是软件实现（overlay 补丁未生效）***`。
- 若确实是软件：检查 `build_kernel.sh` 里的 `Replace` 路径与 `go env GOROOT` 是否一致、
  以及 Xcode 是否绕过了本脚本直接复用了旧的 `libclash.a`（曾发生：内核没重编，
  xcodebuild 只花 15s 就"成功"了）。

## 收益（2026-09-12 真机实测）

| 指标 | 修复前 | 修复后 |
|---|---|---|
| `[cpu-feat]` | `aesgcm256=22MB/s`（软件） | `aesctr≈4.3GB/s`（硬件） |
| 真机 CPU profile（20s） | `ghashMul` 28.6% + `ghash-range1` 4.6% + `aes.encryptBlockGeneric` 15.9% ≈ **49%** | 三者**全部为 0** |
| 总 CPU | 287%（272 Mbps） | 184%（299 Mbps） |
| 吞吐（公网源 4 连接） | 272.27 Mbps | 298.78 Mbps |


## 维护

- 补丁只开 4 项（AES/PMULL/SHA1/SHA2），与上游 macOS 分支的**硬编码值完全一致**；不碰需要 sysctl 动态探测的项。
- Go 版本升级后，若上游把 iOS 也纳入 `cpu_arm64_darwin.go`，本补丁可直接删除（`build_kernel.sh` 会自动跳过不存在的映射？不会 —— 届时删掉 `-overlay` 参数与 `cpu_arm64_other.go` 即可）。
- overlay 是"构建期注入"，**不修改 Go 安装目录**，也不影响桌面/其他平台的构建。
