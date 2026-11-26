// Copyright 2020 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// ============================================================================
// 本文件是 Go 标准库 src/internal/cpu/cpu_arm64_other.go 的**补丁副本**。
//
// 由 ios/toolchain/build_kernel.sh 以 `go build -overlay=<json>` 的方式替换原文件
// 参与 iOS 内核编译（原文件本身不被修改，Go 安装目录保持干净）。
//
// 为什么需要补：原文件在 iOS 上 osInit() 是**空函数**（注释原文："Other operating
// systems do not support reading HWCap ... to detect CPU features at runtime"），
// 于是 ARM64.HasAES / HasPMULL / HasSHA1 / HasSHA2 全为 false —— 虽然 build tag
// 里明明写了 ios。实测后果（2026-09-12 真机 [cpu-feat] 自证）：
//
//	[cpu-feat] arm64 feat: aes=false pmull=false sha1=false sha2=false ... | aesgcm256=22MB/s
//
// 由此 crypto/aes 走 encryptBlockGeneric、GCM 的 GHASH 走 ghashMul（纯软件）。
// 272Mbps 负载的 CPU profile 里 ghashMul 28.6% + ghash-range1 4.6% +
// encryptBlockGeneric 15.9% ≈ 总 CPU 的 49% 全耗在这两处软件实现上，
// 而 lfexp 的载荷加密正是 AES-256-GCM（transport/lfexp/protocol/aead.go）。
//
// 注意：不能改用 GODEBUG=cpu.aes=on 绕过 —— iOS 上没人能在 Go runtime 初始化
// 之前设置环境变量（扩展进程由 dyld 加载即完成 runtime 初始化，NEPacketTunnelProvider
// 的 init()/startTunnel() 里 setenv 都已太晚，实测无效）；编译期 //go:debug cpu.aes=on
// 也被编译器拒绝（"unknown //go:debug setting"，该机制只认 internal/godebugs 注册项）。
//
//go:build arm64 && !linux && !freebsd && !android && (!darwin || ios) && !openbsd && !windows

package cpu

func osInit() {
	// 与上游 cpu_arm64_darwin.go（macOS，非 iOS）保持**完全相同**的语义。
	// 上游原话：There are no hw.optional sysctl values for the below features on
	// macOS 11 to detect their supported state dynamically ... Assume the CPU
	// features that Apple Silicon M1 supports to be available on all future
	// iterations.
	//
	// 也就是说：在 Apple 平台上，这四项本来就是"假定存在"而非"探测得到"。
	// 这些指令属于 armv8 Crypto Extensions，自 Apple A7 起全系具备，
	// Apple 平台不存在缺失该特性的机型。
	//
	// iOS 之所以拿不到这段逻辑，仅仅因为上游那个文件的 build tag 是
	// `arm64 && darwin && !ios`，与 CPU 能力无关。
	//
	// 只开这四项（Apple 全系确定具备）；不碰 ATOMICS / CRC32 / SHA3 / SHA512 /
	// DIT / SB —— 那些在 macOS 上要靠 sysctl(hw.optional.arm.*) 动态探测，
	// iOS 沙箱下不保证可读，保持保守。
	ARM64.HasAES = true
	ARM64.HasPMULL = true
	ARM64.HasSHA1 = true
	ARM64.HasSHA2 = true
}
