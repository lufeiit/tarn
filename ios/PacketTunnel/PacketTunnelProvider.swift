import Foundation
import NetworkExtension

/// 从 IP 包头部解析协议号（IPv4: byte 9, IPv6: byte 6）
private func ipProtocolNumber(_ data: Data) -> NSNumber {
    guard data.count >= 10 else { return NSNumber(value: 0) }
    let version = data[data.startIndex] >> 4
    let proto: UInt8 = version == 6 ? data[data.startIndex + 6] : data[data.startIndex + 9]
    return NSNumber(value: proto)
}

/// 诊断用：把字节片段打成 "xx xx xx"（拆成独立函数，避免长表达式拖垮类型检查）
private func hexDump(_ bytes: ArraySlice<UInt8>) -> String {
    guard !bytes.isEmpty else { return "" }
    var out = String()
    out.reserveCapacity(bytes.count * 3)
    for (i, b) in bytes.enumerated() {
        if i > 0 { out += " " }
        out += String(format: "%02x", b)
    }
    return out
}

/// TCP 头关键字段（用于轨迹诊断）
private struct TcpHdr {
    var sport: UInt16 = 0
    var dport: UInt16 = 0
    var seq: UInt32 = 0
    var ack: UInt32 = 0
    var flags: UInt8 = 0
    var window: UInt16 = 0
}

/// 进程 phys_footprint（KB）：与 Go 侧 iosPhysFootprint 同源，用于 Swift 侧
/// 自己判定内存抬头并做限速（jetsam 按 footprint 判）。
private func iosFootprintKB() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { p -> kern_return_t in
        p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ip in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), ip, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return 0 }
    return Int(info.phys_footprint / 1024)
}

/// 从帧里（ipOff = IP 头起始偏移，帧含 4 字节 AF 头所以通常是 4）解析 TCP 头。
/// 独立函数：避免闭包内复杂表达式导致 Swift 类型检查超时。
private func parseTcp(_ buf: [UInt8], _ ipOff: Int, _ n: Int) -> TcpHdr? {
    guard buf.count > ipOff + 20, n > ipOff + 20 else { return nil }
    let ver: UInt8 = buf[ipOff] >> 4
    let ipHdrLen: Int = ver == 6 ? 40 : Int(buf[ipOff] & 0x0f) * 4
    let t: Int = ipOff + ipHdrLen
    guard n > t + 20, buf.count > t + 20 else { return nil }
    var h = TcpHdr()
    h.sport = UInt16(buf[t]) << 8 | UInt16(buf[t + 1])
    h.dport = UInt16(buf[t + 2]) << 8 | UInt16(buf[t + 3])
    let s0 = UInt32(buf[t + 4]); let s1 = UInt32(buf[t + 5])
    let s2 = UInt32(buf[t + 6]); let s3 = UInt32(buf[t + 7])
    h.seq = s0 << 24 | s1 << 16 | s2 << 8 | s3
    let a0 = UInt32(buf[t + 8]); let a1 = UInt32(buf[t + 9])
    let a2 = UInt32(buf[t + 10]); let a3 = UInt32(buf[t + 11])
    h.ack = a0 << 24 | a1 << 16 | a2 << 8 | a3
    h.flags = buf[t + 13]
    h.window = UInt16(buf[t + 14]) << 8 | UInt16(buf[t + 15])
    return h
}

/// VPN 扩展主实现：承载 Go 核心（libclash），桥接 packetFlow。
class PacketTunnelProvider: NEPacketTunnelProvider {

    private var coreStarted = false
    private var bridgeFD: Int32 = -1
    private var bridgeSock: Int32 = -1
    private var kernelFD: Int32 = -1
    private var kernelFdHandedOff = false
    private var bridgeSource: DispatchSourceRead?
    // fd 桥事件全部串行化到这条私有队列。DispatchSource 的 handler 挂在并发
    // global queue 上**不保证串行**，加上 hitCap 时的主动再排队，drainFd 会出现
    // 多实例并发 ⇒ 计数器竞争、writePackets 分块乱序（触发对端重传，正好加重
    // 多流并发时的吞吐塌方）、pace suspend/resume 与 teardown 竞态（2026-10 审查）。
    private let bridgeQueue = DispatchQueue(
        label: "com.laona.lufeicloud.packet-tunnel.fdbridge",
        qos: .userInitiated)

    // fd 桥参数：
    // - MTU 1500（不是 Hako 的 4064）：socketpair 是 AF_UNIX/SOCK_DGRAM，单报文
    //   受内核上限约制（macOS/iOS net.local.dgram.maxdgram ≈ 2048）。真机实测：
    //   内核 TCP 的 SYN-ACK seq=3377717305，紧随其后的数据段 seq=3377719354，
    //   差值恰好 2048 —— 即那个 4+2048=2052 字节数据报被吞，应用只 ACK 到期望
    //   字节并把后绡段当乱序丢弃，于是页面永远卡死。1500 时数据报 ≤1504 ✅。
    // - 512KB socket 缓冲：数据报排队空间。
    // fd 桥 MTU。
    //
    // 历史：4064 → 1500（当时判定 AF_UNIX SOCK_DGRAM 单报文上限 ~2048，
    // 2052 字节的段被吞，表现为「只进不出」）。但 **Hako 的 iOS 数据面同样是
    // socketpair、默认 MTU = 4064**（`bind/hako/tun.go: defaultTunMTU`，
    // min1280/max9000）—— 说明这个上限要么不成立、要么他们的写侧另有用意。
    //
    // 为什么值得重试：实测隧道 19.5Mbps 时只有 **1630 包/秒**
    // （stall=0 / SLOW=0 / GAP=0，即「速率受限」而不是「停顿」）。
    // MTU 1500→4064 = 包数少 2.7 倍，若瓶颈是每包开销就是 ~53Mbps。
    private static let fdBridgeMTU = 4064
    // socketpair 缓冲：512KB → 1MB。多流并发时下载方向要在这条 socketpair 上
    // 排队，512KB（≈100ms@40Mbps）一旦写满，Go 侧写就会顶住整条链路
    // （中继→gVisor→设备），表现为吞吐塌方 + 6s 级停顿。
    private static let fdBridgeSockBuf: Int32 = 1024 * 1024
    private static let fdBridgeBatchMax = 512
    // 协议号 NSNumber 缓存：每包新建一个 NSNumber 在高吞吐下是纯浪费
    private static let numProto: [UInt8: NSNumber] = [
        6: NSNumber(value: 6), 17: NSNumber(value: 17), 1: NSNumber(value: 1), 0: NSNumber(value: 0),
    ]

    // fd 桥计数（5s 汇总一条，用于判断丢包与吞吐）
    private var fdIn = 0
    private var fdInBytes = 0
    private var fdDropIn = 0
    private var fdOut = 0
    private var fdOutBytes = 0
    private var fdDropOut = 0
    private var fdInHexCount = 0
    private var fdOutHexCount = 0
    private var fdInTcp = 0
    private var fdInUdp = 0
    private var fdInOther = 0
    private var fdOutTcp = 0
    private var fdOutUdp = 0
    private var fdOutOther = 0
    private var fdInTcpHex = 0
    private var fdOutTcpHex = 0
    private var fdInTrace = 0
    private var fdOutTrace = 0
    private var fdOutSyn = 0
    private var fdOutSynAck = 0
    private var fdOutAck = 0
    private var fdOutRst = 0
    private var fdOutFin = 0
    // recv 系统错误计数（EAGAIN 之外的 errno，2026-10 审查时与「只剩地址族头」
    // 的 n<=4 分支拆开）
    private var fdRecvErr = 0
    // 诊断：writePackets 慢调用计数 / drain 事件间隔
    private var fdWriteSlow = 0
    private var fdDrainGaps = 0
    private var fdLastDrainAt: TimeInterval = 0
    // 内存安全阀：默认**关闭**（extPace=true 才开）。
    //
    // 2026-09-12 复盘：它**没有**降低内存（pf 依然 40MB→48MB 一路涨到被杀），
    // 却把出站读源挂起 50~400ms、每秒触发 8 次 —— 这本身就是「只有几 Mbps」
    // 的成因之一（挂起期间下载完全停滞）。真正的内存问题在 gVisor 每连接
    // 窗口（Default=Max=512KB × 几十条连接）与 GC 策略上，已另行修复。
    private static let fdBridgePaceFootprintKB = 46000
    /// 见上：只在明确要压内存时开启。
    private lazy var fdPaceEnabled: Bool = {
        UserDefaults(suiteName: groupId)?.bool(forKey: "extPace") ?? false
    }()
    // gVisor TCP 窗口（KB）——吞吐 ≈ 窗口 / RTT，RTT 实测 ≈110ms：
    //   64KB → 4.6Mbps/连接，1MB → 72Mbps/连接。
    // **起始窗口小、自适应上限大**：空闲连接停在 64KB（不占内存），
    // 只有真在跑 bulk 的连接才长到 1MB（gVisor 自适应窗口，moderate=true 时启用）。
    // 如果起始窗口也放大（旧值 512KB = Default=Max），每条连接都预占 512KB，
    // 几十条并发就是 20~30MB → pf 撞 50MB 被 jetsam 杀。
    //
    // 上限 1024 → 256（2026-09-12 真机实测）：用户真实 speedtest 时 pf 冲到
    // 34~41MB（被杀点），而 19 条流 × 1MB 窗口就 ≈19MB。用「真实节点+公网源」
    // 作代理复现：改 256KB 后 pf 峰值 41MB → 30.8MB、闸门拒绝 653 → 0、
    // 吞吐无回退（386Mbps@128s）。代价：单连接在高 RTT 上极限吞吐封顶
    //（~35Mbps@256KB/60ms），但 iOS 侧本就靠多条并发，总带宽才是用户感知。
    private static let tunBufRecvStartKB: Int32 = 64
    private static let tunBufRecvMaxKB: Int32 = 256
    private static let tunBufSendStartKB: Int32 = 128
    private static let tunBufSendMaxKB: Int32 = 256
    private var fdPaceActive = false
    private var fdPaceStops = 0
    private var fdRateAt: TimeInterval = 0
    private var fdRateInBytes = 0
    private var fdRateOutBytes = 0
    private var fdLastLog: TimeInterval = 0
    // 入站发送缓冲（4 字节 AF 头 + IP 包），复用避免每包分配
    private var fdTxBuf = [UInt8](repeating: 0, count: 65536 + 4)
    // 出站接收缓冲（drainFd 用，只在 bridgeQueue 上触碰）：复用避免每个 drain
    // 事件分配 + 清零 64KB（hitCap 时 drain 可到每秒几十次）
    private var fdRxBuf = [UInt8](repeating: 0, count: 65536)
    // MARK: - 硬件 AES：为什么这里**没有** setenv("GODEBUG", ...)
    //
    // 曾经在这里（以及 startTunnel 里）尝试过 setenv("GODEBUG", "cpu.aes=on,...")
    // 来打开 iOS 上缺失的 arm64 硬件 AES —— **实测无效**，已移除，别再试：
    // Go runtime 在扩展进程被 dyld 加载时即完成初始化并快照 environ，而
    // NEPacketTunnelProvider 的 init()/startTunnel() 都晚于此时刻
    // （真机 [cpu-feat] 仍打印 aes=false）。
    //
    // 正确做法是构建期用 -overlay 给标准库补 osInit()，见：
    //   ios/toolchain/build_kernel.sh + ios/toolchain/README.md
    // 内核侧的自证/告警在 core/cpu_features_ios.go（日志行 [cpu-feat]）。

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        ciProviderRef = self   // Darwin 回调是 C 函数指针拿不到 self，这里留一份引用给 CI 停机通知
        auditPreviousExit()   // 先把"上一次是怎么结束的"记下来，再开始这一代
        NSLog("[ClashCore] startTunnel begin")

        // 诊断通道 ②（Swift/Go）：把内核 stdout/stderr（mihomo 日志，含 DNS/DoT
        // 解析细节、gvisor 栈报错）重定向到 App Group 容器 extDiag.txt，
        // 主 App 走 VpnBridge.readExtLog 读，devicectl 也能直接拉取。
        // 同时注入 TARN_DIAG_DIR，让 Go 侧（Tarn 解析/握手、iosDiagMem）落盘到同一目录。
        if extDiagOn, let logContainer = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupId) {
            // 清理旧位置（App Group 根）遗留的诊断文件，避免新旧混读
            removeLegacyRootDiagFiles(logContainer)
            // 无界增长保护：freopen 是 append 模式，不截断会一直涨
            // （Go 侧 15s 一条 [mem-sampler]，一天就 ~5MB）
            rotateExtDiagIfNeeded()
            if let logURL = diagFileURL("extDiag.txt") {
                _ = freopen(logURL.path, "a", stdout)
                _ = freopen(logURL.path, "a", stderr)
                // 记下这笔账：运行中开关关掉时（租约到期/面板下调），extDiagOn 那个沿会把它
                // 摘回 /dev/null；不记就会一路写到隧道结束（2026-10-28 真机就是这样多写了 51 分钟）。
                extDiagStdioAttached = true
                if let dir = diagDirURL() {
                    setenv("TARN_DIAG_DIR", dir.path, 1)
                }
            } else {
                reportDiagError("startTunnel: diagFileURL 为 nil，extDiag 无法落盘")
            }
            // 诊断探针：根目录到底能不能写（结果只走 UD —— 文件通道本身可疑）
            probeGroupContainer(logContainer)
        } else {
            reportDiagError("startTunnel: containerURL 返回 nil（groupId=\(groupId)）")
        }

        extLog("startTunnel begin")
        // 数据面就绪标记先清掉：主 App 靠「文件存在 + at 时间是本次会话」
        // 判断能否开始全量测速（见 markDataPlaneReady 注释）。
        clearDataPlaneReady()
        // 顺带清掉上一会话遗留的孤儿结果文件（见 sweepResultFiles 注释）。
        sweepResultFiles()
        // 最小隧道实验开关：true 时完全跳过 Go 内核与 App Group，
        // 只做网络设置 + 收包（用于二分定位：扩展能否被系统拉起 + 建立连接）。
        let minMode = UserDefaults(suiteName: groupId)?.bool(forKey: "extMinMode") ?? false
        extLog("minMode=\(minMode)")
        // fd 桥实验：SOCK_DGRAM socketpair 接到 packetFlow，内核走 sing-tun
        // NativeTun(fdbased)（Hako 方案）。**默认开启**：之前靠主 App 写
        // UD 开关，实测因写入时机（隧道已连接时早退）一直没写成，P0 白跑。
        // UD 显式写 false 仍可关闭（VpnBridge.setFdBridge(false)）。
        let fdPref = UserDefaults(suiteName: groupId)?.object(forKey: "extFdBridge") as? Bool
        var fdBridge = fdPref ?? true
        teardownFdBridge() // 防御：上次会话异常结束时先回收 fd 与读源
        if fdBridge {
            var sv: [Int32] = [0, 0]
            if socketpair(AF_UNIX, SOCK_DGRAM, 0, &sv) == 0 {
                bridgeFD = sv[0]
                bridgeSock = sv[1]
                // 内核端拿 dup：sing-tun 接管该 fd 并在 tun 关闭时 close 它，
                // 直接把 bridgeFD 交出去会成为「一个 fd 两个主人」（重复 close
                // 会误关别的 fd）。Swift 保留原始 fd 用于取消。
                kernelFD = dup(bridgeFD)
                if kernelFD < 0 {
                    extLog("fdBridge dup failed errno=\(errno) -> fallback 内存桥")
                    close(bridgeFD)
                    close(bridgeSock)
                    bridgeFD = -1
                    bridgeSock = -1
                    fdBridge = false
                } else {
                    // 两端都设非阻塞：内核慢时宁可丢包计数，也不能阻塞 NEFlow
                    // 回调线程（阻塞会把整个数据面卡死）。
                    for f in [bridgeFD, bridgeSock, kernelFD] where f >= 0 {
                        _ = fcntl(f, F_SETFL, O_NONBLOCK)
                    }
                    // AF_UNIX 数据报的排队上限由缓冲决定：两端都加大，避免内核读不急
                    // 时我们的 send 直接失败（之前 dropIn=34 就是 sv[0] 接收缓冲满）。
                    setSockBuf(bridgeFD, Self.fdBridgeSockBuf)
                    setSockBuf(bridgeSock, Self.fdBridgeSockBuf)
                    extLog("fdBridge socketpair ok fd=\(bridgeFD) sock=\(bridgeSock) kernelFD=\(kernelFD) mtu=\(Self.fdBridgeMTU) sockBuf=\(sockBuf(bridgeSock, SO_SNDBUF))/\(sockBuf(bridgeFD, SO_RCVBUF))")
                }
            } else {
                extLog("fdBridge socketpair failed errno=\(errno) -> fallback 内存桥")
                fdBridge = false
            }
        }
        extLog("fdBridge=\(fdBridge)")
        if minMode {
            let mSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunnelRemoteAddress)
            mSettings.mtu = 9000
            mSettings.ipv4Settings = Self.makeIPv4Settings()
            setTunnelNetworkSettings(mSettings) { error in
                if let error = error {
                    extLog("min tunnel setTunnelNetworkSettings failed: \(error.localizedDescription)")
                    self.cancelTunnelWithError(error)
                    completionHandler(error)
                    return
                }
                extLog("min tunnel settings applied, completing")
                self.startReadingPackets()
                completionHandler(nil)
            }
            return
        }

        // 1. 注册核心回调（结果回写 App Group，供主 App 读取）
        ClashCore.setResultHandler({ _, data in
            guard let data = data else { return }
            // autoreleasepool：该回调由 Go 在自己的线程上同步调用，
            // 该线程没有 ObjC 自动释放池 ⇒ 不包池会让 String/Data 持续累积（计入 phys_footprint）。
            autoreleasepool {
                let msg = String(cString: data)
                // 降噪：逐条落盘会把 startTunnel/config 等关键行挤出 UD 环形缓冲
                logResultThrottled("resultHandler msg=\(msg.prefix(120))")
                completeQuickSetup(msg)
                // 前缀判别再决定是否全量 JSON 解析：结果消息（ActionResult，Go
                // struct 字段序 Id/Method/Data/Code）顶层首键必为 "id"；推送类
                // 消息（Message{Type, Data}）首键是 "type"。statistic 的
                // DefaultRequestNotify 每条新连接都推一条 request 消息，测速期间
                // 不判别就是每连接一次完整解析 + 一次跨进程通知的纯浪费（2026-10 审查）。
                if msg.hasPrefix("{\"id\"") {
                    writeResultToGroup(msg)
                }
            }
        }, nil) { _ in }

        ClashCore.setPacketWriter({ ctx, data, len in
            guard let ctx = ctx, let data = data, len > 0 else { return }
            // ⚠️ 必须包 autoreleasepool：该回调由 Go 在自己的线程上**同步**调用，
            // 而 Go 的线程没有 ObjC 自动释放池 ⇒ 每个包创建的 Data/NSNumber
            // 会持续累积（实测 pf 从 15MB 单调涨到 60MB 而 Go heap 仅 8~13MB，
            // 正好对得上：这部分内存不在 Go 堆里）。
            autoreleasepool {
                let provider = Unmanaged<PacketTunnelProvider>
                    .fromOpaque(ctx).takeUnretainedValue()
                let packet = Data(bytes: data, count: Int(len))
                // 出站反压（2026-09-12）：`NEPacketTunnelFlow.writePackets` 在这
                // 个 SDK 里**没有 completionHandler 变体**（只同步返回 Bool），
                // 所以拿不到「iOS 内部队列已满」的信号。退一步用返回值做轻量反压：
                // 写失败就睡 1ms，避免 Go 侧无脑压包把内部队列堆起来（那部分内存
                // 记在我们进程的 footprint 上，实测 Speedtest 期间 pf 涨到 43MB
                // 撞 50MB jetsam）。
                if !provider.packetFlow.writePackets([packet], withProtocols: [ipProtocolNumber(packet)]) {
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }
        }, Unmanaged.passUnretained(self).toOpaque())

        // 2. 从 App Group 读取运行配置（P4 完善：由主 App 写入）
        //    先使用默认值占位，确保链路可跑通
        //
        // ⚠ IPv6 必须一并接管（2026-09-12 实测）。原实现只给内核 v4 前缀、
        // 且 NEPacketTunnelNetworkSettings 从不设 ipv6Settings ⇒ **设备上的
        // IPv6 流量完全绕过 VPN**（本机探测 hasIpv6=true，且大多数 CDN/测速源
        // 都有 AAAA 记录：真机自测打 tokyo linode 时隧道只过了 4MB / 应用下了
        // 50MB）。既是严重的漏流量，也让「速度快慢」的观测完全失真。
        let address = "198.18.0.1/30,fd00:198:18::1/64"
        let dns = "1.1.1.1,223.5.5.5"
        let (initParams, setupParams) = Self.loadConfigFromAppGroup() ?? ("{}", "{}")
        // 诊断：配置长度落 extDiag.txt（+ UD extLog 双保险）。
        // 「扩展读到 "{}" → 内核零节点 → 测速全 -1」这类问题一眼可判：
        //   initLen=2 setupLen=2      → 三级读取都没命中（配置文件通道坏了）
        //   setupLen≈251991           → 读到真实配置（getProxies 应 ~93KB/217 代理）
        extLog("startTunnel config initLen=\(initParams.count) setupLen=\(setupParams.count)")

        // 3. 初始化核心；quickSetup 异步，必须等结果后才能启动 TUN。
        let setupWaiter = beginQuickSetupWait()
        extLog("calling quickSetup")
        // cString 返回 nil 仅在 OOM：nil 传给 Go 的 takeCString 会在
        // C.GoString(nil) 上崩，必须就地取消而不是传下去。
        guard let initC = cString(initParams), let setupC = cString(setupParams) else {
            extLog("cString OOM (init/setup) — cancel tunnel")
            let error = NSError(domain: "LufeiCloud.PacketTunnel", code: 4,
                                 userInfo: [NSLocalizedDescriptionKey: "内存不足（配置拷贝失败）"])
            cancelTunnelWithError(error)
            completionHandler(error)
            return
        }
        ClashCore.quickSetup(nil, initC, setupC)
        guard let setupResult = waitForQuickSetup(setupWaiter) else {
            extLog("quickSetup timed out")
            let error = NSError(domain: "LufeiCloud.PacketTunnel", code: 1,
                                 userInfo: [NSLocalizedDescriptionKey: "核心初始化超时"])
            cancelTunnelWithError(error)
            completionHandler(error)
            return
        }
        guard setupResult.isEmpty else {
            extLog("quickSetup failed: \(setupResult)")
            let error = NSError(domain: "LufeiCloud.PacketTunnel", code: 2,
                                 userInfo: [NSLocalizedDescriptionKey: setupResult])
            cancelTunnelWithError(error)
            completionHandler(error)
            return
        }
        extLog("quickSetup completed")

        // 4. 启动 TUN（gvisor 栈，fd = -1 表示 packetFlow 模式）
        extLog("calling startTUN fd=\(kernelFD)")
        // gVisor TCP 窗口必须走 Go 侧**显式 setter**：darwin 上 Go runtime 启动时会
        // 快照 environ，Swift 的 libc setenv 它读不到 ⇒ 旧代码的
        // setenv("TARN_TUN_TCP_BUF_KB") 从来没有生效过，内核一直用 512KB 默认值
        // （每连接预占 512KB，几十条并发 ⇒ pf 撞 50MB 被杀）。
        ClashCore.setTunBufKB(Self.tunBufRecvStartKB, Self.tunBufRecvMaxKB,
                              Self.tunBufSendStartKB, Self.tunBufSendMaxKB)
        extLog("tun tcp win KB recv=\(Self.tunBufRecvStartKB)..\(Self.tunBufRecvMaxKB) send=\(Self.tunBufSendStartKB)..\(Self.tunBufSendMaxKB)")
        guard let stackC = cString("gvisor"),
              let addressC = cString(address),
              let dnsC = cString(dns) else {
            extLog("cString OOM (tun args) — cancel tunnel")
            let error = NSError(domain: "LufeiCloud.PacketTunnel", code: 4,
                                 userInfo: [NSLocalizedDescriptionKey: "内存不足（TUN 参数拷贝失败）"])
            cancelTunnelWithError(error)
            completionHandler(error)
            return
        }
        // 返回值必须检查：内核侧 sing_tun.New 失败（地址解析错 / 栈建不起来 /
        // fd 桥接不上）时，原实现照样 markDataPlaneReady ⇒ 「VPN 已连接但数据面
        // 全死」且主 App 立即全量测速（2026-10 审查）。失败时 cancel，让系统按
        // on-demand 重拉扩展。
        let tunOK = ClashCore.startTUN(nil, kernelFD, stackC, addressC, dnsC)
        // fd 所有权：成功 = 交给内核（sing-tun 负责 close）；失败 = Go 侧未接管，
        // 交还 Swift 由 teardownFdBridge 关闭（个别 sing-tun 内部失败路径若已自行
        // close，重复 close 最多 EBADF，进程随即随 cancel 退出，无复用风险）。
        kernelFdHandedOff = tunOK != 0
        // quickSetup 已成功：无论 TUN 是否起来，stopTunnel 都要停内核
        coreStarted = true
        guard tunOK != 0 else {
            extLog("startTUN failed — cancel tunnel")
            let error = NSError(domain: "LufeiCloud.PacketTunnel", code: 3,
                                 userInfo: [NSLocalizedDescriptionKey: "内核 TUN 启动失败"])
            cancelTunnelWithError(error)
            completionHandler(error)
            return
        }
        extLog("startTUN returned")

        // 5. 配置网络设置
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunnelRemoteAddress)
        // MTU 必须与内核一致：fd 桥 4064（socketpair 单报文上限），内存桥沿用 9000。
        // 诊断热调 tun-mtu.txt（Go 侧 core/tun/tun_ios.go: iosTunMTUOverride）时
        // 必须双侧读同一文件，否则 NE 按大 MTU 发、内核按小 MTU 收（2026-10 审查）。
        settings.mtu = NSNumber(value: Self.tunMtuFromFile() ?? (fdBridge ? Self.fdBridgeMTU : 9000))
        settings.ipv4Settings = Self.makeIPv4Settings()
        // IPv6 同样全量接管（见上面 address 注释）：漏 v6 = 漏流量
        settings.ipv6Settings = Self.makeIPv6Settings()
        settings.dnsSettings = NEDNSSettings(servers: dnsServers)
        settings.dnsSettings?.matchDomains = [""]

        // 6. 监听主 App 的动作消息（Darwin notify + App Group msgQueue）
        addMessageObserver()
        processPendingMessages()
        startMsgPollTimer()

        setTunnelNetworkSettings(settings) { error in
            if let error = error {
                extLog("setTunnelNetworkSettings failed: \(error.localizedDescription)")
                self.cancelTunnelWithError(error)
                completionHandler(error)
                return
            }
            extLog("network settings applied: addr=\(address) dns=\(dns) mtu=\(settings.mtu)")
            // 数据面真正可用的时刻 = setTunnelNetworkSettings 回调成功
            // （系统只有在此之后才会把 NE 置为 connected）。写标记通知主 App。
            // 注意：markDataPlaneReady 是**文件级**函数，不能加 self. 前缀。
            markDataPlaneReady()
            self.startReadingPackets()
            completionHandler(nil)
        }
    }

    private func startReadingPackets() {        // 循环读取 packetFlow 收到的 IP 包，送入 Go 核心
        // fd 桥模式：packetFlow 收到的包直接 send 到 socketpair（fdbased 读）
        if bridgeSock >= 0 {
            // 读源只建一次：之前每收到一批包就调一次 fdBridgeReadLoop()，会把旧源
            // 覆盖掉且从不 cancel，同一个 fd 上堆叠几百个 read source。
            if bridgeSource == nil {
                fdBridgeReadLoop()
            }
            packetFlow.readPackets { [weak self] packets, _ in
                guard let self = self else { return }
                // autoreleasepool：高吞吐（Speedtest）下这个回调每秒被调很多次，
                // 不包裹的话 NEFlow 产生的 Data 会在池里累积（实测非 Go 侧内存
                // 30 秒涨了 ~8MB，和 Go 侧一起把 pf 顶到 43MB 被 jetsam 杀掉）。
                autoreleasepool {
                    for p in packets {
                        p.withUnsafeBytes { raw in
                            guard let base = raw.baseAddress, raw.count > 0 else { return }
                            let n = raw.count
                            // ⚠ utun 帧格式：每报文 = 4 字节地址族头 + IP 包。
                            // sing-tun 的 fdbased_darwin 写侧 prefix packetHeader4/6、
                            // 读侧 TrimFront(4)，两端都必须按这个约定，否则内核把 IP
                            // 头前 4 字节当地址族头 ⇒ 全部丢包（表现为只进不出）。
                            guard n + 4 <= self.fdTxBuf.count else {
                                self.fdDropIn += 1
                                return
                            }
                            self.fdTxBuf[3] = ((raw[0] >> 4) == 6) ? 30 : 2 // AF_INET6 / AF_INET
                            memcpy(&self.fdTxBuf[4], base, n)
                            let sent = self.fdTxBuf.withUnsafeBytes { buf in
                                send(self.bridgeSock, buf.baseAddress, n + 4, 0)
                            }
                            if sent < 0 {
                                self.fdDropIn += 1
                                // 前几次把 errno 打出来：用于定性「是单报文上限
                                // （EMSGSIZE=40）还是缓冲满（ENOBUFS=55/EAGAIN=35）」
                                if self.fdDropIn <= 5 {
                                    extLog("fdBridge send FAIL n=\(n + 4) errno=\(errno) dropIn#\(self.fdDropIn)")
                                }
                            } else {
                                self.fdIn += 1
                                self.fdInBytes += n
                                // 协议构成（IPv4 偏移 9 / IPv6 偏移 6）
                                let ver = raw[0] >> 4
                                let off = ver == 6 ? 6 : 9
                                let proto = n > off ? raw[off] : 0
                                if proto == 6 {
                                    self.fdInTcp += 1
                                    if let h = parseTcp(self.fdTxBuf, 4, n + 4) {
                                        if self.fdInTrace < 24 {
                                            self.fdInTrace += 1
                                            let fls = String(format: "%02x", h.flags)
                                            let line = "fdBridge tcpIn#" + String(self.fdInTrace) + " " + String(h.sport) + "->" + String(h.dport)
                                            extLog(line + " fl=0x" + fls + " seq=" + String(h.seq) + " ack=" + String(h.ack) + " win=" + String(h.window) + " len=" + String(n + 4))
                                        }
                                        if self.fdInTcpHex < 3 {
                                            self.fdInTcpHex += 1
                                            let endI: Int = min(96, n + 4)
                                            let dump: String = hexDump(self.fdTxBuf[0..<endI])
                                            extLog("fdBridge tcpInHex#" + String(self.fdInTcpHex) + " bytes=[" + dump + "]")
                                        }
                                    }
                                }
                                else if proto == 17 { self.fdInUdp += 1 }
                                else { self.fdInOther += 1 }
                                if self.fdInHexCount < 6 {
                                    self.fdInHexCount += 1
                                    let endI: Int = min(60, n + 4)
                                    let dump: String = hexDump(self.fdTxBuf[0..<endI])
                                    extLog("fdBridge in#" + String(self.fdInHexCount) + " ver=" + String(ver) + " proto=" + String(proto) + " len=" + String(n + 4) + " bytes=[" + dump + "]")
                                }
                            }
                        }
                    }
                    // fdBridgeLog 的节流/速率状态也被 drainFd（bridgeQueue）触碰：
                    // 本回调跑在 NE 的读回调线程上，统计行排到 bridgeQueue，
                    // 保证这套状态单线程。fdIn*/fdOut* 各方向只有单一写者，
                    // 跨线程只被本函数读取（64 位对齐读，良性）。
                    let force = self.fdIn <= 1
                    self.bridgeQueue.async { self.fdBridgeLog(force: force) }
                }
                self.startReadingPackets()
            }
            return
        }
        // 默认（内存桥）：循环读取 packetFlow 收到的 IP 包，送入 Go 核心
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self = self else { return }
            // autoreleasepool：见上面 fdBridge 分支同样原因（高吞吐下必加）
            autoreleasepool {
                for p in packets {
                    p.withUnsafeBytes { raw in
                        if let base = raw.baseAddress {
                            ClashCore.packetInput(UnsafeMutableRawPointer(mutating: base), Int32(raw.count))
                        }
                    }
                }
            }
            self.startReadingPackets()
        }
    }

    // fd 桥读循环：socketpair(sv[1]) -> packetFlow.writePackets
    // 一次事件把可读的数据报全部取走并批量写回：逐包 recv + 逐包 writePackets
    // 在高吞吐（Speedtest）下会把系统调用与分配数量放大一个量级。
    private func fdBridgeReadLoop() {
        let fd = bridgeSock
        // 串行队列：见 bridgeQueue 属性注释（并发 global queue 上 handler 不保证串行）
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: bridgeQueue)
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            autoreleasepool {
                // 内存安全阀：footprint 超过阈值就**挂起读源**暂停投递，靠 TCP 背压让
                // 内核停止拉取，终止堆积。实测 Speedtest 只有 3Mbps 时 10 秒就撞 42MB
                // 被 jetsam 杀：下载被窗口限流、ACK 回不来，未确认数据在扩展里堆积。
                let fp = iosFootprintKB()
                if self.fdPaceEnabled && fp >= Self.fdBridgePaceFootprintKB {
                    if !self.fdPaceActive {
                        self.fdPaceActive = true
                        self.fdPaceStops += 1
                        // 固定挂起 50ms 后在本串行队列恢复（挂起期间靠 TCP 背压
                        // 停止拉取；此前注释写「50ms→最快 400ms」与实际 min(5n,50)
                        // 封顶 50ms 不符，2026-10 修正）
                        let pauseMs = min(5 * self.fdPaceStops, 50)
                        extLog("fdBridge pace ON pf=\(fp)KB stop=\(self.fdPaceStops) pause=\(pauseMs)ms")
                        self.bridgeSource?.suspend()
                        // 恢复也排到本串行队列：fdPaceActive / suspend / resume
                        // 只在这条队列上触碰（teardown 例外，见其注释）。
                        self.bridgeQueue.asyncAfter(deadline: .now() + .milliseconds(pauseMs)) { [weak self] in
                            guard let self = self else { return }
                            if self.fdPaceActive {
                                self.fdPaceActive = false
                                self.bridgeSource?.resume()
                                extLog("fdBridge pace OFF pf=\(iosFootprintKB())KB")
                            }
                        }
                    }
                    return
                }
                if self.fdPaceStops != 0 && fp < Self.fdBridgePaceFootprintKB - 4000 {
                    // 回落到阈值下 4MB 才清零计数，避免在阀值附近抖动
                    self.fdPaceStops = 0
                }
                self.drainFd()
            }
        }
        source.resume()
        bridgeSource = source
    }

    /// 把 socketpair 里可读的数据报一次取尽、批量写回 packetFlow。
    /// 只在 bridgeQueue 上运行（读源 handler 与 hitCap 再排队都在这条队列）。
    private func drainFd() {
                var batch: [Data] = []
                var protocols: [NSNumber] = []
                batch.reserveCapacity(Self.fdBridgeBatchMax)
                protocols.reserveCapacity(Self.fdBridgeBatchMax)
                // 接收缓冲复用实例属性 fdRxBuf（只在 bridgeQueue 触碰），不再每次
                // drain 分配 + 清零 64KB。fdRxLen 先取出：recv 的 inout 和同一属性
                // 的 count 读取不能出现在同一调用里（Swift 独占访问冲突）。
                let fdRxLen = fdRxBuf.count
                var hitCap = false
                while true {
                    if batch.count >= Self.fdBridgeBatchMax {
                        // 取到上限：说明 socketpair 里还有积压。就地下一次
                        // drain 排队 —— 实测读源每秒只唤醒 ~3 次，若一次只取
                        // 64 包，吞吐会被钉在 ~188 pkt/s（≈2Mbps），这正是
                        // TUN 路径只有 1.5Mbps 的直接原因。
                        hitCap = true
                        break
                    }
                    let n = recv(bridgeSock, &fdRxBuf, fdRxLen, 0)
                    if n < 0 {
                        // 非阻塞下的 EAGAIN = 本轮取尽（正常出口）；其他 errno
                        // 单独记数 —— 不再和「只剩地址族头」的 n<=4 混在一起
                        // （2026-10 审查）。
                        if errno == EAGAIN || errno == EWOULDBLOCK { break }
                        fdRecvErr += 1
                        if fdRecvErr <= 5 {
                            extLog("fdBridge recv FAIL errno=\(errno) err#\(fdRecvErr)")
                        }
                        break
                    }
                    if n <= 4 { break } // 关闭 / 只剩地址族头
                    let buf = fdRxBuf
                    // 剥 4 字节地址族头（AF_INET=2 / AF_INET6=30）后再交给系统
                    let pkt = Data(buf[4..<n])
                    batch.append(pkt)
                    // protocols 参数取「包的 IP 协议号」（Apple 头文件：the protocol of
                    // the packet）：IPv4 在头内偏移 9、IPv6 在偏移 6。与内存桥路径
                    // 的 ipProtocolNumber 同一取法，之前写死 1/6 与它不一致。
                    let ver = buf[4] >> 4
                    let hdrOff = ver == 6 ? 6 : 9
                    let protoNum: UInt8 = (4 + hdrOff) < n ? buf[4 + hdrOff] : 0
                    protocols.append(Self.numProto[protoNum] ?? NSNumber(value: protoNum))
                    self.fdOut += 1
                    self.fdOutBytes += n - 4
                    if protoNum == 6 {
                        self.fdOutTcp += 1
                        if let h = parseTcp(buf, 4, n) {
                            let fl: UInt8 = h.flags
                            if fl & 0x02 != 0 { self.fdOutSyn += 1 }
                            if fl & 0x12 == 0x12 { self.fdOutSynAck += 1 }
                            if fl & 0x10 != 0 { self.fdOutAck += 1 }
                            if fl & 0x04 != 0 { self.fdOutRst += 1 }
                            if fl & 0x01 != 0 { self.fdOutFin += 1 }
                            if self.fdOutTrace < 24 {
                                self.fdOutTrace += 1
                                let fls = String(format: "%02x", fl)
                                let line = "fdBridge tcpOut#" + String(self.fdOutTrace) + " " + String(h.sport) + "->" + String(h.dport)
                                extLog(line + " fl=0x" + fls + " seq=" + String(h.seq) + " ack=" + String(h.ack) + " win=" + String(h.window) + " len=" + String(n))
                            }
                            if self.fdOutTcpHex < 3 {
                                self.fdOutTcpHex += 1
                                let endI: Int = min(96, n)
                                let dump: String = hexDump(buf[0..<endI])
                                extLog("fdBridge tcpOutHex#" + String(self.fdOutTcpHex) + " bytes=[" + dump + "]")
                            }
                        }
                    }
                    else if protoNum == 17 { self.fdOutUdp += 1 }
                    else { self.fdOutOther += 1 }
                    if self.fdOutHexCount < 6 {
                        self.fdOutHexCount += 1
                        let endI: Int = min(60, n)
                        let dump: String = hexDump(buf[0..<endI])
                        extLog("fdBridge out#" + String(self.fdOutHexCount) + " ver=" + String(ver) + " proto=" + String(protoNum) + " len=" + String(n) + " bytes=[" + dump + "]")
                    }
                }
                if !batch.isEmpty {
                    // 批量投递（每包 3 个 ObjC 分配 + 一次 syscall 在高吞吐下太贵）：
                    // 分块调用 writePackets，块内多包一次系统调用。
                    //
                    // 计时诊断：多流并发时吞吐会塌到几 Mbps，必须区分
                    // 「Swift → 设备这一侧卡住」还是「上游没数据可送」。
                    // writePackets 是同步调用，它一慢整个 drain 循环就停，
                    // Go 侧写 socketpair 随即被顶住（中继→gVisor→设备全链停）。
                    var i = 0
                    while i < batch.count {
                        let end = min(i + 32, batch.count)
                        let sub = Array(batch[i..<end])
                        let protos = Array(protocols[i..<end])
                        let wpStart = Date()
                        if !self.packetFlow.writePackets(sub, withProtocols: protos) {
                            self.fdDropOut += sub.count
                        }
                        let wpMs = Date().timeIntervalSince(wpStart) * 1000
                        if wpMs > 300 {
                            self.fdWriteSlow += 1
                            if self.fdWriteSlow <= 40 {
                                extLog("fdBridge writePackets SLOW \(Int(wpMs))ms pkts=\(sub.count) pfslow#\(self.fdWriteSlow)")
                            }
                        }
                        i = end
                    }
                    // drain 事件间隔：> 2s 说明这一侧压根没被唤醒（不是我们慢）。
                    let nowAt = Date().timeIntervalSince1970
                    if self.fdLastDrainAt > 0 {
                        let gap = nowAt - self.fdLastDrainAt
                        if gap > 2.0 {
                            self.fdDrainGaps += 1
                            if self.fdDrainGaps <= 40 {
                                extLog("fdBridge drain GAP \(String(format: "%.1f", gap))s gap#\(self.fdDrainGaps) out=\(self.fdOut)")
                            }
                        }
                    }
                    self.fdLastDrainAt = nowAt
                    self.fdBridgeLog(force: self.fdOut <= Self.fdBridgeBatchMax)
                }
                if hitCap {
                    // 还有积压：立刻再排一次 drain，不要等下个可读事件。
                    // 排到 bridgeQueue（串行）：与读源 handler、pace 恢复互斥，
                    // drainFd 不会再出现多实例并发（2026-10 审查前是 global 并发队列）。
                    bridgeQueue.async { [weak self] in
                        guard let self = self else { return }
                        if self.bridgeSock >= 0 { self.drainFd() }
                    }
                }
    }

    /// 回收 fd 桥资源（可重复调用）：取消读源 + 关闭 Swift 侧 fd。
    /// 单一释放点：close 只在 teardown 里做，避免 cancelHandler 与 teardown 双关。
    private func teardownFdBridge() {
        // 若正被安全阀挂起，先恢复再 cancel（挂起源上 cancel 不会跑取消处理）
        if fdPaceActive {
            fdPaceActive = false
            bridgeSource?.resume()
        }
        bridgeSource?.cancel()
        bridgeSource = nil
        if bridgeSock >= 0 {
            close(bridgeSock)
            bridgeSock = -1
        }
        if bridgeFD >= 0 {
            close(bridgeFD)
            bridgeFD = -1
        }
        // kernelFD 一旦交给内核（startTUN 成功）就由 sing-tun 释放；没交出去
        // 就自己关，避免每次失败重试泄漏一个 fd。
        if kernelFD >= 0, !kernelFdHandedOff {
            close(kernelFD)
        }
        kernelFD = -1
        kernelFdHandedOff = false
    }

    /// fd 桥计数（5s 一条）：in=收进内核、out=写出给系统、dropIn/dropOut=丢弃。
    private func fdBridgeLog(force: Bool) {
        let now = Date().timeIntervalSince1970
        if !force && now - fdLastLog < 5 { return }
        fdLastLog = now
        let p1 = "fdBridge in=\(fdIn) inB=\(fdInBytes) dropIn=\(fdDropIn)"
        let p2 = "out=\(fdOut) outB=\(fdOutBytes) dropOut=\(fdDropOut)"
        let p3 = "inTcp=\(fdInTcp) inUdp=\(fdInUdp) inOth=\(fdInOther)"
        let p4 = "outTcp=\(fdOutTcp) outUdp=\(fdOutUdp) outOth=\(fdOutOther)"
        let p5 = "outSyn=\(fdOutSyn) outSAck=\(fdOutSynAck) outAck=\(fdOutAck) outRst=\(fdOutRst) outFin=\(fdOutFin)"
        // 速率（相对上次汇总）：直接看出实际吞吐
        let dt = max(0.001, now - fdRateAt)
        let inKBs = Double(fdInBytes - fdRateInBytes) / 1024.0 / dt
        let outKBs = Double(fdOutBytes - fdRateOutBytes) / 1024.0 / dt
        fdRateAt = now
        fdRateInBytes = fdInBytes
        fdRateOutBytes = fdOutBytes
        let p6 = "inKBps=\(Int(inKBs)) outKBps=\(Int(outKBs)) pf=\(iosFootprintKB())KB"
        extLog(p1 + " " + p2 + " " + p3 + " " + p4 + " " + p5 + " " + p6)
    }

    private func setSockBuf(_ fd: Int32, _ size: Int32) {
        var v = size
        let len = socklen_t(MemoryLayout<Int32>.size)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &v, len)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &v, len)
    }

    private func sockBuf(_ fd: Int32, _ opt: Int32) -> Int32 {
        var v: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        _ = getsockopt(fd, SOL_SOCKET, opt, &v, &len)
        return v
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        extLog("stopTunnel reason=\(reason.rawValue), coreStarted=\(coreStarted)")
        // 就绪标记随会话一起失效（否则下次 startTunnel 前主 App 会误判已就绪）
        clearDataPlaneReady()
        // 先摘 Go → Swift 的写出回调：ctx 是 passUnretained(self)，stopTun 之后
        // 若 Go 侧还有在途 WritePacket 回调，会打在即将失效的 self 上（UAF 窗口，
        // 2026-10 审查）。Go 侧 writerFn 为 nil 后走 "writer not set" 丢弃路径。
        ClashCore.setPacketWriter(nil, nil)
        if coreStarted {
            ClashCore.stopTun()
            ClashCore.suspend(true)
        }
        // 读源必须取消、fd 必须关闭：否则每次重连泄漏 2 个 fd + 一个永不停止的
        // 读源（还在往已结束的 packetFlow 写包）。
        teardownFdBridge()
        // 停掉周期任务：cancel 之后进程可能还被系统保留一段时间，让 1s 消息轮询
        // / 30s 热状态上报继续跑是纯浪费（还会往已停止的核心投递动作）。
        msgPollTimer?.cancel()
        msgPollTimer = nil
        thermalTimer?.cancel()
        thermalTimer = nil
        trafficSampleTimer?.cancel()
        trafficSampleTimer = nil
        // 基线也清掉：隧道重启后核心计数从零开始，留着旧基线会算出负增量。
        trafficSampleState = nil
        trafficSampleLoggedAt = nil
        cancelTunnelWithError(nil)
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        // P4: 主 App 通过此通道 / App Group 与扩展交互
        completionHandler?(nil)
    }

    // MARK: - 网络设置（P4 从 App Group 配置读取）

    private var tunnelRemoteAddress: String { "198.18.0.1" }
    private var dnsServers: [String] { ["1.1.1.1", "223.5.5.5"] }

    /// 读取诊断热调的内核 MTU：与 Go 侧 core/tun/tun_ios.go `iosTunMTUOverride`
    /// 同一文件（`<AppGroup>/Library/tun-mtu.txt`）、同一取值范围（1280...9000）。
    /// 缺失/非法返回 nil，调用方回退 fd 桥 4064 / 内存桥 9000。
    /// 双侧同源读取才能保证 NE settings.mtu 与内核 gVisor MSS 一致。
    private static func tunMtuFromFile() -> Int? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupId),
              let raw = try? Data(contentsOf: container.appendingPathComponent("Library/tun-mtu.txt")),
              let text = String(data: raw, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              let v = Int(text), (1280...9000).contains(v) else { return nil }
        return v
    }

    private static func makeIPv4Settings() -> NEIPv4Settings {
        let settings = NEIPv4Settings(
            addresses: ["198.18.0.1"],
            subnetMasks: ["255.255.255.252"]
        )
        settings.includedRoutes = [NEIPv4Route.default()]
        return settings
    }

    /// IPv6 侧与 v4 同构：隧道内地址 fd00:198:18::1/64 + 全量路由。
    /// 缺了它就等于把设备的 v6 流量原样丢给直连（漏流量）。
    private static func makeIPv6Settings() -> NEIPv6Settings {
        let settings = NEIPv6Settings(
            addresses: ["fd00:198:18::1"],
            networkPrefixLengths: [64]
        )
        settings.includedRoutes = [NEIPv6Route.default()]
        return settings
    }

    // MARK: - Helpers

    private static func loadConfigFromAppGroup() -> (String, String)? {
        // 文件通道优先：主 App 原子写入 App Group 容器（跨进程读可靠，已验证）；
        // UserDefaults(suiteName:) 兜底。
        if let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupId),
           let initData = try? Data(contentsOf: container.appendingPathComponent("initParams.json")),
           let setupData = try? Data(contentsOf: container.appendingPathComponent("setupParams.json")),
           let initParams = String(data: initData, encoding: .utf8)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           let setupParams = String(data: setupData, encoding: .utf8)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !initParams.isEmpty, !setupParams.isEmpty {
            return (initParams, setupParams)
        }
        // 与主 App 的 UserDefaults(suiteName:) 保持一致（同 plist）
        guard let ud = UserDefaults(suiteName: groupId),
              let initParams = ud.string(forKey: "initParams"),
              let setupParams = ud.string(forKey: "setupParams"),
              !initParams.isEmpty, !setupParams.isEmpty else {
            return nil
        }
        return (initParams, setupParams)
    }
}

// MARK: - 顶层 App Group 消息循环（C 回调不可捕获 Self/上下文，故用顶层函数）

private func infoString(_ key: String, fallback: String) -> String {
    (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? fallback
}

private let groupId = infoString("TarnAppGroup", fallback: "group.com.tarn.app")
private var msgPollTimer: DispatchSourceTimer?

// MARK: - 诊断落盘位置（App Group 的 Library/ 子目录）

/// 诊断目录：App Group 容器的 `Library/` 子目录。
///
/// **为什么不用容器根**：`xcrun devicectl` 对 App Group 域**既不列出也拷不走根级文件**
/// —— `device info files` 只枚举 `Library/` 子树，`device copy from --source extDiag.txt`
/// 直接报 7000。落到 `Library/` 下才能被直接拉取（实测 `Library/probe-ext.txt` 可以拷到）。
/// Go 侧同理由 `TARN_DIAG_DIR` 指到这里（见 `constant`/`common.go: iosDiagDir`）。
private func diagDirURL() -> URL? {
    guard let container = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: groupId) else {
        return nil
    }
    let dir = container.appendingPathComponent("Library", isDirectory: true)
    if !FileManager.default.fileExists(atPath: dir.path) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    return dir
}

/// 诊断文件 URL（`Library/<name>`）。
private func diagFileURL(_ name: String) -> URL? {
    diagDirURL()?.appendingPathComponent(name)
}

// MARK: - 开机审计：上一次是怎么结束的（2026-10-28 真机）
//
// 真机现象：VPN 连着重启两次（04:40:41 / 04:40:59 各起一个进程，活了 16s 与 1s），用户那边
// 只看到"掉了一下又回来"。判据不用猜 —— 正常关闭一定会写下 `stopTunnel reason=…`，被系统收掉
// 或崩溃就没有这一行（本次第一个进程 998 就是这么消失的：末行 04:40:29，之后什么都没有）。
// 所以启动的第一行先把上一段日志的收尾读出来摆着，只陈述证据，不猜原因。
private var bootAudited = false

private func auditPreviousExit() {
    guard !bootAudited else { return }
    bootAudited = true
    guard extDiagOn, let url = diagFileURL("extDiag.txt"),
          let handle = try? FileHandle(forReadingFrom: url) else { return }
    defer { try? handle.close() }
    // offset() 在新 SDK 里是 throws 的（CI 实测：error: call can throw …）
    guard let size = try? handle.offset(), size > 0 else { return }
    let back = min(size, 8192)
    handle.seek(toFileOffset: size - back)
    guard let data = try? handle.read(upToCount: Int(back)) else { return }
    // 切尾 8KB 的起点几乎必然落在多字节汉字中间：严格解码这时返回 nil —— 真机实测就是
    // 「[boot-audit] 一整行都没写出来」的原因（日志里中文行占绝大多数）。改成容忍坏字节，
    // 并把可能被切坏的首行丢掉：我们只关心最后一行，首行残缺无所谓。
    var text = String(decoding: data, as: UTF8.self)
    if back < size, let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    guard let last = lines.last else { return }
    // 只认我们自己的收尾格式；本进程的行这时还没写进来（审计是 startTunnel 的第一件事）
    let stopped = lines.contains { $0.contains("stopTunnel reason=") }
    if stopped {
        extLog("boot-audit 上次正常收尾（有 stopTunnel 记录）；末行: \(last.prefix(120))")
    } else {
        extLog("boot-audit 上次退出没写 stopTunnel —— 进程被系统收掉或崩溃的形态；末行: \(last.prefix(120))")
    }
}

// MARK: - 数据面就绪标记（主 App ⇄ 扩展）
//
// 背景（2026-09-11 真机实测）：主 App 会在 startTunnel **同一毫秒**派发全部
// 209 个测速（日志实测 21:17:40.359 派发 / 21:17:40.0 startTunnel），而数据面
// 要到 ~0.7s 后才就绪（network settings applied）。撞在这个窗口里的拨号大量
// reality 握手 err=EOF，被节点 1s 退避锁死后直接 -1 —— 表现为「刚拉起系统
// VPN 时前 20~40 个节点全部 timeout」。
//
// 通道：`<group>/Library/dp-ready.json`（JSON，原子写）。
//   startTunnel 开头 **删除** → 文件存在即代表「本次会话已就绪」，
//   主 App 只需等文件出现，不用额外 IPC。
/// 写入就绪标记（`setTunnelNetworkSettings` 成功后）。
private func markDataPlaneReady() {
    guard let url = diagFileURL("dp-ready.json") else {
        reportDiagError("markDataPlaneReady: diagFileURL 为 nil")
        return
    }
    let payload: [String: Any] = [
        "at": Int(Date().timeIntervalSince1970 * 1000),
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
    do {
        try data.write(to: url, options: .atomic)
        NSLog("[ClashCore] data plane ready marker written")
        startThermalReporter()
        startTrafficSampler()
    } catch {
        reportDiagError("markDataPlaneReady write failed: \(error.localizedDescription)")
    }
}

/// 热状态记录（2026-09-19）：用户反馈「开 VPN 待机也发热」，而扩展侧此前只有 CPU%
/// 代理，缺少**系统级**热判据。`ProcessInfo.thermalState` 是降频/jetsam 前系统给出的
/// 客观分级（nominal/fair/serious/critical），且 Foundation 在 NE 扩展里可用
/// （`UIDevice` 的电池 API 在扩展里不可用）。
///
/// 30s 一行落 extDiag.txt；`lowPower` 用 `isLowPowerModeEnabled` —— 用户手动开省电
/// 模式会显著改变功耗画像，必须一起记录，否则 A/B 会被它污染。
private var thermalTimer: DispatchSourceTimer?

private func startThermalReporter() {
    guard thermalTimer == nil else { return }
    let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    t.schedule(deadline: .now() + 5, repeating: 30)
    t.setEventHandler {
        let st: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: st = "nominal(0)"
        case .fair: st = "fair(1)"
        case .serious: st = "serious(2)"
        case .critical: st = "critical(3)"
        @unknown default: st = "unknown"
        }
        let lpm = ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0
        extLog("thermal state=\(st) lowPower=\(lpm)")
    }
    t.resume()
    thermalTimer = t
}

// MARK: - 隧道流量采样（仅诊断包）
//
// 为什么需要（2026-10-27 真机实测）：用户自己开 VPN 跑几轮 Speedtest，切到别的 app
// 之后主 App 被 iOS 冻住 —— App 侧的 getTraffic 轮询和它写的日志全停（实测 13:21–13:43
// vpnlog.txt 与 app.log **各 0 行**），回来只能靠 getTotalTraffic 两头差值看出「这段
// 过了 1.02 GB 下行 / 77.7 MB 上行」，速率完全恢复不出来。NE 扩展不受主 App 挂起影响，
// 所以采样搬到扩展里：每 10 秒一行 `traffic_sample`，带区间增量、折算 Mbps 和累计量。
//
// 两条口径都采，不猜语义：`down/up` 取 `onlyStatisticsProxy=false`（隧道总量），
// `proxy_down/proxy_up` 取 `=true`（只算走代理的）——走直连规则的测速流量只有前者看得见。
//
// 落盘走 extLog：**只有诊断包写文件**，正式版只 NSLog（用户完全无感，也不占 App Group）。
// 静音期 60 秒才一行（否则一天光待机就刷 8000 行），有流量时每 10 秒一行。

private struct TrafficTotals {
    let down: Int64
    let up: Int64
}

private struct TrafficSampleState {
    var all: TrafficTotals
    var proxy: TrafficTotals
    var at: Date
}

private var trafficSampleTimer: DispatchSourceTimer?
private var trafficSampleState: TrafficSampleState?
private var trafficSampleLoggedAt: Date?

private func startTrafficSampler() {
    guard extDiagOn, trafficSampleTimer == nil else { return }
    let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    t.schedule(deadline: .now() + 2, repeating: 10)
    t.setEventHandler { sampleTraffic() }
    t.resume()
    trafficSampleTimer = t
}

/// 读一次核心累计量（`{"down":…,"up":…}`），读不到就不采这一拍。
private func readTrafficTotals(onlyProxy: Bool) -> TrafficTotals? {
    guard let raw = ClashCore.getTraffic(onlyProxy),
          let data = raw.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: data),
          let obj = parsed as? [String: Any] else {
        return nil
    }
    func number(_ key: String) -> Int64 {
        if let n = obj[key] as? NSNumber { return n.int64Value }
        if let s = obj[key] as? String { return Int64(s) ?? 0 }
        return 0
    }
    return TrafficTotals(down: number("down"), up: number("up"))
}

/// 采一拍：算出与上一拍的增量、按实际经过的秒数折算 Mbps，落一行 extDiag。
/// 核心计数倒退（重启/清零）就换基线，不报负数；空闲只在 60 秒心跳时落行。
private func sampleTraffic() {
    guard let all = readTrafficTotals(onlyProxy: false) else { return }
    let proxy = readTrafficTotals(onlyProxy: true) ?? TrafficTotals(down: 0, up: 0)
    let now = Date()
    guard let last = trafficSampleState else {
        trafficSampleState = TrafficSampleState(all: all, proxy: proxy, at: now)
        trafficSampleLoggedAt = now
        extLog("traffic_sample init total_down=\(all.down) total_up=\(all.up) "
            + "proxy_total_down=\(proxy.down) proxy_total_up=\(proxy.up)")
        return
    }
    let dt = now.timeIntervalSince(last.at)
    guard dt > 0.5 else { return }
    let down = all.down - last.all.down
    let up = all.up - last.all.up
    trafficSampleState = TrafficSampleState(all: all, proxy: proxy, at: now)
    if down < 0 || up < 0 {
        extLog("traffic_sample reset total_down=\(all.down) total_up=\(all.up)")
        trafficSampleLoggedAt = now
        return
    }
    let idle = down == 0 && up == 0
    let heartbeat = trafficSampleLoggedAt.map {
        now.timeIntervalSince($0) >= 60
    } ?? true
    guard !idle || heartbeat else { return }
    let mbpsDown = Double(down) * 8 / dt / 1_000_000
    let mbpsUp = Double(up) * 8 / dt / 1_000_000
    trafficSampleLoggedAt = now
    extLog("traffic_sample dt=\(String(format: "%.1f", dt))s down=+\(down) up=+\(up) "
        + "mbps_down=\(String(format: "%.2f", mbpsDown)) "
        + "mbps_up=\(String(format: "%.2f", mbpsUp)) "
        + "total_down=\(all.down) total_up=\(all.up) "
        + "proxy_down=+\(proxy.down - last.proxy.down) "
        + "proxy_up=+\(proxy.up - last.proxy.up)")
}

/// 清除就绪标记（startTunnel 开头 / stopTunnel）。
private func clearDataPlaneReady() {
    guard let url = diagFileURL("dp-ready.json") else { return }
    if FileManager.default.fileExists(atPath: url.path) {
        try? FileManager.default.removeItem(at: url)
        NSLog("[ClashCore] data plane ready marker cleared")
    }
}

/// 清空上一会话遗留的孤儿结果文件（`results/*.json`）。
///
/// 来源：主 App `_invokeExt` 超时后动作可能仍在扩展内处理并于之后写入
/// `results/<id>.json`，没人读取就永久留在 App Group 里。新会话开始时全部清掉
/// 是安全的：id 含毫秒时间戳 + 8 位随机串不会复用（lib/common/utils.dart: id），
/// 且此刻主 App 的旧轮询早已超时。主 App 侧超时路径也做了 best-effort 清理，
/// 两端合起来把孤儿文件的生命周期压到一个会话以内。
private func sweepResultFiles() {
    guard let base = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: groupId) else { return }
    let dir = base.appendingPathComponent("results", isDirectory: true)
    guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
    for f in files where f.hasSuffix(".json") {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
    }
}

/// 删除 App Group **根级**的旧诊断文件（旧版本写在那里，devicectl 取不到，
/// 留着会与 `Library/` 下的新文件混读）。
private func removeLegacyRootDiagFiles(_ container: URL) {
    for name in ["extDiag.txt", "lfexp-diag.log", "go-crash.log"] {
        let url = container.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
            reportDiagError("cleanup: removed legacy root \(name)")
        }
    }
}

/// extDiag.txt 无界增长保护：超过 8MB 时只保留尾部 2MB（按行边界切）。
/// `freopen` 以 append 打开，不主动截断会一直增长（Go 侧 `[mem-sampler]` 15s 一条）。
/// 必须在 `freopen` 之前调用 —— 此时还没有已打开的文件句柄。
private func rotateExtDiagIfNeeded() {
    guard let url = diagFileURL("extDiag.txt"),
          let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
          let size = attrs[.size] as? Int, size > 8 * 1024 * 1024,
          let all = try? Data(contentsOf: url),
          all.count > 2 * 1024 * 1024 else { return }
    // Data → Substring（按 UTF-8 解码；截断点可能落在多字节字符中间，
    // 用 String(decoding:) 会自动替换成 U+FFFD，不会崩）
    var body = String(decoding: all.suffix(2 * 1024 * 1024), as: UTF8.self)[...]
    if let nl = body.firstIndex(of: "\n") {
        body = body[body.index(after: nl)...]
    }
    let marker = "===== extDiag 轮转（超过 8MB，仅保留尾部 2MB）=====\n"
    let out = Data((marker + body).utf8)
    try? out.write(to: url)
    reportDiagError("extDiag 轮转: \(size) -> \(out.count) bytes")
}

// 扩展进程内诊断日志：写入 App Group 容器文件（主 App 可经 groupContainerPath 读取），
// UserDefaults(suiteName:) 在这个 iOS 上跨进程同步不可靠，改走文件。
//
// 2026-09-11 修正：写失败不再静默。失败原因进 UD `diagError`（唯一实测可用的跨进程
// 通道），且**无论容器是否可用都把该行镜像到 UD `extLog`**。
// 背景：实测 App Group 根目录只写进了 `Library/`（UD plist 正常），`extDiag.txt`
// 从未落地，而失败原因被 `catch` 吞掉，导致长期无法定位。
/// 诊断通道总开关（**运行时标记文件**，默认关）：
/// - 诊断版（App 带 `--dart-define=IOS_DIAG=true`）启动时创建 `Library/tarn-diag-on.txt`；
/// - 正式版启动时会**删除**该标记 ⇒ stdout/stderr 不再重定向、`extLog` 不再落盘。
/// 为何不用编译宏：Swift 自定义宏要改 Xcode 工程/xcconfig，而本项目已有“文件热开关”
/// 的成熟模式（`tarn-diag-level.txt` 等），这里与内核侧 `ios_diag` 分层配套使用。
// 诊断开关（App / 内核 / 扩展共用的那个 App Group 文件）：文件在**且租约没到期**才算开。
//
// 为什么带租约（业主 2026-10-28：「我下发了开关后，用户没收到关闭的通知，有没有自动关闭的动作」）：
// 面板的「开」是随订阅下发的，用户不再打开 App 就再也传不过去「关」。文件里写的是到期时间，
// App 每联系一次面板续 7 天；到期后内核侧会写一行说明并把文件删掉，这里也认到期 ⇒
// 最迟 7 天自己熄火，不会一直写下去撑爆储存。
//
// 为什么从 `let`（启动时读一次）改成带 5 秒缓存的计算属性：extLog 每条都要判一次开关，
// 不能每条都去读盘（所以缓存 5 秒）；而 30 秒那几档采样（温度/低电量/流量）本来就在调 extLog，
// 顺带让这个判断自己更新 ⇒ 面板关了采集、或租约到期，**隧道跑着的时候最多 30 秒内停止写**，
// 不必等隧道重启。多线程下最坏是偶尔多读一次盘，不影响正确性。
private var extDiagOnCached: Bool = false
private var extDiagOnCachedAt: Date = .distantPast

private var extDiagOn: Bool {
    if Date().timeIntervalSince(extDiagOnCachedAt) < 5 { return extDiagOnCached }
    extDiagOnCachedAt = Date()
    extDiagOnCached = extDiagOnFileLive()
    // 「开→关」这个沿上把 stdout/stderr 也从日志文件上摘下来：那一路 freopen 是隧道启动时按
    // 当时的开关状态决定的，运行中不改指就不经过任何门槛（2026-10-28 真机实测：租约 16:40
    // 到期，[ext] 当刻停了，freopen 那一路 [ClashCore] fdBridge/thermal 行却写到了 17:31）。
    // 摘回 /dev/null 后最迟下一次 extLog（几秒内）就断。NSLog 的内容仍进系统日志，这里断的
    // 只是"系统日志往这个文件里镜像"的那一份。
    if extDiagStdioAttached && !extDiagOnCached {
        extDiagStdioAttached = false
        detachExtDiagStdio()
    }
    return extDiagOnCached
}

/// startTunnel 里那对 freopen 现在还挂着吗（只在"开→关"这个沿上用它摘一次）。
private var extDiagStdioAttached = false

/// 运行中把 stdout/stderr 从 extDiag.txt 改指 /dev/null（与 startTunnel 同一套 freopen）。
private func detachExtDiagStdio() {
    _ = freopen("/dev/null", "w", stdout)
    _ = freopen("/dev/null", "w", stderr)
}

/// 开关文件算不算"开着"：存在且租约没到期。内容是到期时间（本机时区带 +0800 偏移，
/// 与 extDiagStamp 同一套写法）。内容读不懂（老包写的 "1"、写到一半被截断）时按文件修改时间
/// + 7 天：老包每次启动都会重写这个文件，mtime 就是"上次确认开着"的时刻，与老语义一致。
private func extDiagOnFileLive() -> Bool {
    guard let url = diagFileURL("tarn-diag-on.txt") else { return false }
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
          let mtime = attrs[.modificationDate] as? Date else { return false }
    let body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    if let until = extDiagDeadline(from: body) { return until > Date() }
    return mtime.addingTimeInterval(7 * 24 * 3600) > Date()
}

/// 从文件内容里认出一个到期时刻（固定 25 字符：`2026-11-04T08:05:00+0800`）。
/// 按那一行自带的偏移解释成绝对时刻 ⇒ 用户换时区不会被本地时区变化误判。
private func extDiagDeadline(from body: String) -> Date? {
    for raw in body.components(separatedBy: "\n") {
        let c = Array(raw.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
        guard c.count >= 25 else { continue }
        func num(_ at: Int, _ n: Int) -> Int? { Int(String(c[at..<(at + n)])) }
        guard c[10] == "T", c[20] == "+" || c[20] == "-",
              let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2),
              let h = num(11, 2), let mi = num(14, 2), let se = num(17, 2),
              let oh = num(21, 2), let om = num(23, 2) else { continue }
        var comp = DateComponents()
        comp.year = y; comp.month = mo; comp.day = d
        comp.hour = h; comp.minute = mi; comp.second = se
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: (c[20] == "-" ? -1 : 1) * (oh * 3600 + om * 60))
            ?? .current
        if let date = cal.date(from: comp) { return date }
    }
    return nil
}

// extDiagStamp 落盘时间戳：设备本地时间并带 +0800 这类偏移，跟 Go 侧
// iosExtStampLayout（"2006-01-02 15:04:05 -0700"）同一个口径。
// 原先写的是 \(Date())，那是 **UTC**（"2026-10-27 20:34:46 +0000"）—— 同一份 extDiag.txt
// 里 Go 侧的行是 +0800，两批行混在一起，对着手表读日志的人会把时间线看串（2026-10-28 真机
// 实测就是这样）。扩展进程里 TimeZone.current 是准的（不像 Go 找不到 /etc/localtime），
// 所以直接按本地时间格式化，并把偏移写进串里自证。
private let extDiagStamp: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZ"
    return f
}()

private func extLog(_ s: String) {
    guard extDiagOn else {
        // 正式版：只留系统日志（NSLog），不落 App Group 文件
        NSLog("[ClashCore] %@", s)
        return
    }
    let line = "\(extDiagStamp.string(from: Date())) [ext] \(s)"
    NSLog("[ClashCore] %@", s)
    guard let url = diagFileURL("extDiag.txt") else {
        NSLog("[ClashCore] extLog: no app group container, dropping: %@", s)
        reportDiagError("extLog: containerURL 返回 nil (groupId=\(groupId))")
        mirrorExtLogToUD(line)
        return
    }
    do {
        let data = (line + "\n").data(using: .utf8) ?? Data()
        if FileManager.default.fileExists(atPath: url.path) {
            let fh = try FileHandle(forWritingTo: url)
            fh.seekToEndOfFile()
            fh.write(data)
            fh.closeFile()
        } else {
            try data.write(to: url)
        }
    } catch {
        NSLog("[ClashCore] extLog write failed: %@", "\(error)")
        reportDiagError("extLog write FAILED path=\(url.path) err=\(error)")
    }
    mirrorExtLogToUD(line)
}

/// 把一行诊断镜像到 App Group UserDefaults（唯一实测稳定的跨进程通道）。
/// 上限 20000 字符：实测 8000 时会被 `resultHandler msg=` 刷满，
/// 把 `startTunnel begin` / `config initLen=` 等关键行挤出去（62 行里 0 条关键行）。
private func mirrorExtLogToUD(_ line: String) {
    guard let ud = UserDefaults(suiteName: groupId) else { return }
    let prev = ud.string(forKey: "extLog") ?? ""
    let combined = (prev.isEmpty ? "" : prev + "\n") + line
    ud.set(String(combined.suffix(20000)), forKey: "extLog")
}

private var lastResultLogAt = Date(timeIntervalSince1970: 0)

/// 结果回调日志节流：最多每 1s 一条。
/// 测速并发时 resultHandler 每秒可回数条，逐条落 extLog 会把关键行挤出 UD 环形缓冲。
private func logResultThrottled(_ s: String) {
    // 2026-09-19 能耗归因：原为 1s 窗口 ⇒ 空闲期实测仍有 ~50 行/分，而每行都是一次
    // 文件写。响应内容只在排查「有没有回话 / 回了什么」时才有用，30s 一行足够。
    let now = Date()
    if now.timeIntervalSince(lastResultLogAt) < 30.0 { return }
    lastResultLogAt = now
    extLog(s)
}

/// 诊断错误上报：失败原因进 UD `diagError`（主 App `readExtLog` 会一并带出来）。
/// 只走 UserDefaults、绝不走文件 —— 否则"上报写失败"这件事自己就会失败。
private func reportDiagError(_ msg: String) {
    NSLog("[ClashCore][diag] %@", msg)
    guard let ud = UserDefaults(suiteName: groupId) else { return }
    let prev = ud.string(forKey: "diagError") ?? ""
    let line = "\(Date()) \(msg)"
    ud.set(String(((prev.isEmpty ? "" : prev + "\n") + line).suffix(4000)),
           forKey: "diagError")
}

/// 探针：验证 App Group 容器各位置可写性（结果只走 UD）。
private func probeGroupContainer(_ container: URL) {
    let fm = FileManager.default
    reportDiagError("probe: container=\(container.path)")
    let rootEntries = (try? fm.contentsOfDirectory(atPath: container.path)) ?? []
    reportDiagError("probe: rootEntries=[\(rootEntries.joined(separator: ", "))]")

    let probeURL = container.appendingPathComponent("probe-ext.txt")
    do {
        try Data("\(Date())\n".utf8).write(to: probeURL)
        reportDiagError("probe: root write OK")
    } catch {
        reportDiagError("probe: root write FAILED err=\(error)")
    }

    let probeDir = container.appendingPathComponent("probe-ext-dir")
    do {
        try fm.createDirectory(at: probeDir, withIntermediateDirectories: true)
        reportDiagError("probe: root mkdir OK")
    } catch {
        reportDiagError("probe: root mkdir FAILED err=\(error)")
    }

    // 对照组：Library/（UD plist 就在这里，预期可写）
    do {
        try Data("\(Date())\n".utf8)
            .write(to: container.appendingPathComponent("Library/probe-ext.txt"))
        reportDiagError("probe: Library write OK")
    } catch {
        reportDiagError("probe: Library write FAILED err=\(error)")
    }

    let diagPath = container.appendingPathComponent("extDiag.txt").path
    reportDiagError("probe: extDiag exists=\(fm.fileExists(atPath: diagPath))")
}

// notifyName：主 App 与扩展之间那条 App Group 消息通道的 Darwin 通知名（写结果后 post、
// 收到后 processPendingMessages）。f7b190fa 加 CI 停机通知时把它这一行**换成了** ciStopNotifyName
// 而不是新加一行，两处使用（注册观察者 / 发通知）就悬空了 —— CI 编译报
// "cannot find 'notifyName' in scope"（run 799，两个品牌同时红）。名字别改：它是跨进程约定，
// 改了老 App 发的通知新扩展收不到。
private let notifyName = infoString("TarnCoreNotify", fallback: "com.tarn.app.coreMsg")
private let ciStopNotifyName = "cn.lufei.ci.stop.vpn"
private var ciStopObserverInstalled = false
private weak var ciProviderRef: PacketTunnelProvider?
private var groupObserverInstalled = false
private let quickSetupLock = NSLock()
private var quickSetupWaiter: DispatchSemaphore?
private var quickSetupResult: String?

private func beginQuickSetupWait() -> DispatchSemaphore {
    let waiter = DispatchSemaphore(value: 0)
    quickSetupLock.lock()
    quickSetupWaiter = waiter
    quickSetupResult = nil
    quickSetupLock.unlock()
    return waiter
}

private func completeQuickSetup(_ result: String) {
    quickSetupLock.lock()
    guard let waiter = quickSetupWaiter else {
        quickSetupLock.unlock()
        return
    }
    quickSetupWaiter = nil
    quickSetupResult = result
    quickSetupLock.unlock()
    waiter.signal()
}

private func waitForQuickSetup(_ waiter: DispatchSemaphore) -> String? {
    guard waiter.wait(timeout: .now() + .seconds(15)) == .success else {
        quickSetupLock.lock()
        if quickSetupWaiter === waiter {
            quickSetupWaiter = nil
        }
        quickSetupLock.unlock()
        return nil
    }
    quickSetupLock.lock()
    let result = quickSetupResult
    quickSetupResult = nil
    quickSetupLock.unlock()
    return result
}

/// strdup 一份 C 字符串交给 Go 侧（quickSetup / startTUN / invokeAction）。
/// 所有权：Go 侧 takeCString 用 C.free 释放（bride_ios.go），Swift 不再 free。
/// 返回 nil 仅在 OOM —— 调用方必须判空：nil 传给 Go 的 takeCString 会在
/// C.GoString(nil) 上崩溃（2026-10 审查；此前 startTunnel 里还有一份重复的
/// static 实现，已合并到这里）。
private func cString(_ s: String) -> UnsafeMutablePointer<CChar>? {
    strdup(s)
}

// msgQueue 轮询兜底：Darwin 通知跨进程在扩展内不可靠（run28 实测），
// 每 1s 轮询 App Group msgQueue，确保消息必达。
private func startMsgPollTimer() {
    guard msgPollTimer == nil else { return }
    let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    t.schedule(deadline: .now(), repeating: .seconds(1))
    t.setEventHandler { processPendingMessages() }
    t.resume()
    msgPollTimer = t
}

/// CI 停机通知的落地：扩展自己收尾，形态与用户在 App 里拨开关一致。
///   直接调我们自己的 stopTunnel 覆盖实现 ⇒ 走的是同一套收尾（清就绪标记、停内核、关 fd、
///   取消周期任务），日志里留下一条 stopTunnel reason=1（=userInitiated），与正常关闭完全同形；
///   比 CI 从外面杀进程干净：被杀的隧道会被系统反复拉起（真机实测 04:40 两次 1~16 秒自动重启）。
private func ciStopTunnelFromCI() {
    extLog("ci-stop-vpn 收到 CI 停机通知 ⇒ 扩展主动收尾（等价于用户在开关上拨关）")
    DispatchQueue.main.async {
        guard let p = ciProviderRef else { return }
        p.stopTunnel(with: .userInitiated, completionHandler: {})
    }
}

private func addMessageObserver() {
    if groupObserverInstalled { return }
    groupObserverInstalled = true
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        nil,
        { _, _, _, _, _ in
            processPendingMessages()
        },
        notifyName as CFString,
        nil,
        .deliverImmediately)
    // CI 停机通知挂在同一个注册点上：这里被执行时隧道必然在线（隧道不在线扩展根本不会被拉起）
    if !ciStopObserverInstalled {
        ciStopObserverInstalled = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in ciStopTunnelFromCI() },
            ciStopNotifyName as CFString,
            nil,
            .deliverImmediately)
    }
}

/// 消费消息队列：**文件队列优先**，再兜底 UD 数组。
///
/// 文件队列（`msgqueue/*.json`）每条消息一个独立文件 ⇒ **并发发送安全**；
/// UD 数组是「读-改-写」，并发会互相覆盖丢消息 —— 这正是过去 iOS 侧测速
/// 被迫完全串行（`_delayTail`）的根源，导致 209 节点要 4.4 分钟（桌面只要 1 分钟）。
private var lastMsgQueueMtime: Date?
private var msgQueueTick = 0

private func processPendingMessages() {
    var messages: [String] = []
    if let base = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: groupId) {
        let dir = base.appendingPathComponent("msgqueue", isDirectory: true)
        // 廉价门控（2026-09-19 能耗）：本函数每秒被调一次，原来每次都列目录 + 逐个读文件。
        // 目录 mtime 未变 ⇒ 没有新消息，一次 stat 就跳过。**轮询间隔不变（仍 1s），
        // 所以指令延迟不受影响**，只是把空闲每秒的目录扫描省掉。
        let mtime = (try? FileManager.default.attributesOfItem(atPath: dir.path))?[.modificationDate] as? Date
        let unchanged = mtime != nil && mtime == lastMsgQueueMtime
        lastMsgQueueMtime = mtime
        msgQueueTick += 1
        // 每 10 次（10s）强制全扫一次：兜住"目录 mtime 因任何原因未更新"的极端情况，
        // 代价是 10s 一次目录列举（原来每秒一次）。
        let forceScan = msgQueueTick % 10 == 0
        if forceScan || !unchanged,
           let files = try? FileManager.default.contentsOfDirectory(
               at: dir, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension == "json" {
                if let data = try? Data(contentsOf: f),
                   let s = String(data: data, encoding: .utf8), !s.isEmpty {
                    messages.append(s)
                }
                // 读完即删（文件通道无需回写，天然无竞态）
                try? FileManager.default.removeItem(at: f)
            }
        }
    }
    let ud = UserDefaults(suiteName: groupId)
    let queue = (ud?.array(forKey: "msgQueue") as? [String]) ?? []
    if !queue.isEmpty {
        messages.append(contentsOf: queue)
        ud?.set([String](), forKey: "msgQueue")
    }
    if messages.isEmpty { return }
    for json in messages {
        guard let action = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: action) as? [String: Any],
              let _ = obj["id"] as? String else {
            continue
        }
        // 注：**不再写占位符**。文件通道下「读不到结果」本身就代表「还在处理」，
        // 主 App 会继续轮询；占位符反而会让它把占位当成最终结果（历史 bug）。
        guard let actionC = cString(json) else {
            extLog("cString OOM — drop action msg")
            continue
        }
        ClashCore.invokeAction(nil, actionC)
    }
}

/// 内核结果回写 App Group（主 App 轮询 readResult）。
/// **文件优先**：`results/<id>.json` 原子写、实时可见、并发安全；UD 字典保留作兜底。
private func writeResultToGroup(_ msg: String) {
    guard let data = msg.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let id = obj["id"] as? String else {
        return
    }
    if let base = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: groupId) {
        let dir = base.appendingPathComponent("results", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? msg.data(using: .utf8)?.write(
            to: dir.appendingPathComponent("\(id).json"), options: .atomic)
    }
    // 2026-10-07：不再写 UD `results` 字典。该字典实测 8000+ 条 / 7.7MB，
    // 每次结果都要「读取全量-改-写回」⇒ 扩展启动瞬间 phys_footprint +20MB
    // （低内存时被 jetsam 秒杀，表现为「开关拉不起系统 VPN」；
    // 高内存时虽不杀但也会让每次结果处理都产生大额瞬时分配）。
    // 文件通道本就是主通道（见上方注释），UD 字典为旧版兜底，停用。
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFNotificationName(notifyName as CFString),
        nil, nil, true)
}
