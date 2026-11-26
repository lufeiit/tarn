import Foundation

// MARK: - Go 核心 C API 声明（对应 libclash.h）

enum ClashCore {
    // 生命周期
    static func quickSetup(
        _ callback: UnsafeMutableRawPointer?, _ initParams: UnsafeMutablePointer<CChar>?,
        _ setupParams: UnsafeMutablePointer<CChar>?
    ) {
        clash_quickSetup(callback, initParams, setupParams)
    }

    static func invokeAction(_ callback: UnsafeMutableRawPointer?, _ params: UnsafeMutablePointer<CChar>?) {
        clash_invokeAction(callback, params)
    }

    static func startTUN(
        _ callback: UnsafeMutableRawPointer?, _ fd: Int32,
        _ stack: UnsafeMutablePointer<CChar>?, _ address: UnsafeMutablePointer<CChar>?,
        _ dns: UnsafeMutablePointer<CChar>?
    ) -> UInt8 {
        clash_startTUN(callback, fd, stack, address, dns)
    }

    /// 设置 gVisor TCP 窗口（KB：recvStart/recvMax/sendStart/sendMax）。
    /// 必须在 startTUN 之前调用；不能靠环境变量（darwin 上 Go 启动时快照 environ，
    /// Swift 的 libc setenv 它读不到）。
    static func setTunBufKB(_ recvStart: Int32, _ recvMax: Int32,
                            _ sendStart: Int32, _ sendMax: Int32) {
        clash_setTunBufKB(recvStart, recvMax, sendStart, sendMax)
    }

    static func setEventListener(_ listener: UnsafeMutableRawPointer?) {
        clash_setEventListener(listener)
    }

    static func getTraffic(_ onlyStatisticsProxy: Bool) -> String? {
        // 内核返回 malloc 的 C 字符串，所有权在调用方（见 core/lib.go
        // getTotalTraffic/getTraffic 注释）：拷成 String 后立即 free。
        // 旧实现内核侧 defer C.free，调用方拿到的是悬垂指针（UAF）。
        guard let c = clash_getTotalTraffic(onlyStatisticsProxy) else { return nil }
        defer { free(c) }
        return String(cString: c)
    }

    static func stopTun() { clash_stopTun() }
    static func suspend(_ v: Bool) { clash_suspend(v) }
    static func forceGC() { clash_forceGC() }
    static func updateDns(_ s: UnsafeMutablePointer<CChar>?) { clash_updateDns(s) }

    // iOS 桥
    // fn 可为 nil：stopTunnel 时置空回调，消除「Go 在途 WritePacket 回调打在
    // 已失效的 ctx（passUnretained(self)）上」的 UAF 窗口。Go 侧 writerFn 为 nil
    // 时 WritePacket 走 "ios packet writer is not set" 丢弃路径。
    static func setPacketWriter(
        _ fn: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>?, Int32) -> Void)?,
        _ ctx: UnsafeMutableRawPointer?
    ) {
        clash_setIOSPacketWriter(fn, ctx)
    }

    static func packetInput(_ data: UnsafeMutableRawPointer?, _ length: Int32) {
        clash_iosPacketInput(data, length)
    }

    static func setResultHandler(
        _ fn: @escaping @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>?) -> Void,
        _ ctx: UnsafeMutableRawPointer?,
        _ releaseFn: @escaping @convention(c) (UnsafeMutableRawPointer?) -> Void
    ) {
        clash_setIOSResultHandler(fn, ctx, releaseFn)
    }
}

// C 函数声明（链接自 libclash）
#if !targetEnvironment(simulator)
@_silgen_name("quickSetup")
func clash_quickSetup(_ callback: UnsafeMutableRawPointer?, _ initParams: UnsafeMutablePointer<CChar>?, _ setupParams: UnsafeMutablePointer<CChar>?)

@_silgen_name("invokeAction")
func clash_invokeAction(_ callback: UnsafeMutableRawPointer?, _ params: UnsafeMutablePointer<CChar>?)

@_silgen_name("startTUN")
func clash_startTUN(_ callback: UnsafeMutableRawPointer?, _ fd: Int32, _ stack: UnsafeMutablePointer<CChar>?, _ address: UnsafeMutablePointer<CChar>?, _ dns: UnsafeMutablePointer<CChar>?) -> UInt8

@_silgen_name("setTunBufKB")
func clash_setTunBufKB(_ recvStart: Int32, _ recvMax: Int32, _ sendStart: Int32, _ sendMax: Int32)

@_silgen_name("setEventListener")
func clash_setEventListener(_ listener: UnsafeMutableRawPointer?)

@_silgen_name("getTotalTraffic")
func clash_getTotalTraffic(_ onlyStatisticsProxy: Bool) -> UnsafeMutablePointer<CChar>?

@_silgen_name("stopTun")
func clash_stopTun()

@_silgen_name("suspend")
func clash_suspend(_ suspended: Bool)

@_silgen_name("forceGC")
func clash_forceGC()

@_silgen_name("updateDns")
func clash_updateDns(_ s: UnsafeMutablePointer<CChar>?)

@_silgen_name("setIOSPacketWriter")
func clash_setIOSPacketWriter(_ fn: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>?, Int32) -> Void)?, _ ctx: UnsafeMutableRawPointer?)

@_silgen_name("iosPacketInput")
func clash_iosPacketInput(_ data: UnsafeMutableRawPointer?, _ length: Int32)

@_silgen_name("setIOSResultHandler")
func clash_setIOSResultHandler(_ fn: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>?) -> Void, _ ctx: UnsafeMutableRawPointer?, _ releaseFn: @convention(c) (UnsafeMutableRawPointer?) -> Void)
#endif

#if targetEnvironment(simulator)
// 模拟器不跑内核，仅保证链接
func clash_quickSetup(_ callback: UnsafeMutableRawPointer?, _ initParams: UnsafeMutablePointer<CChar>?, _ setupParams: UnsafeMutablePointer<CChar>?) { }
func clash_invokeAction(_ callback: UnsafeMutableRawPointer?, _ params: UnsafeMutablePointer<CChar>?) { }
func clash_startTUN(_ callback: UnsafeMutableRawPointer?, _ fd: Int32, _ stack: UnsafeMutablePointer<CChar>?, _ address: UnsafeMutablePointer<CChar>?, _ dns: UnsafeMutablePointer<CChar>?) -> UInt8 { 0 }
func clash_setTunBufKB(_ recvStart: Int32, _ recvMax: Int32, _ sendStart: Int32, _ sendMax: Int32) { }
func clash_setEventListener(_ listener: UnsafeMutableRawPointer?) { }
func clash_getTotalTraffic(_ onlyStatisticsProxy: Bool) -> UnsafeMutablePointer<CChar>? { nil }
func clash_stopTun() { }
func clash_suspend(_ suspended: Bool) { }
func clash_forceGC() { }
func clash_updateDns(_ s: UnsafeMutablePointer<CChar>?) { }
func clash_setIOSPacketWriter(_ fn: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>?, Int32) -> Void)?, _ ctx: UnsafeMutableRawPointer?) { }
func clash_iosPacketInput(_ data: UnsafeMutableRawPointer?, _ length: Int32) { }
func clash_setIOSResultHandler(_ fn: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>?) -> Void, _ ctx: UnsafeMutableRawPointer?, _ releaseFn: @convention(c) (UnsafeMutableRawPointer?) -> Void) { }
#endif
