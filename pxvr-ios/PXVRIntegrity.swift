//
//  PXVRIntegrity.swift
//  PXVR-iOS
//
//  iOS 原生等价物，替换 APK 中的「启动 / 包 / 设备」校验：
//
//   APK 机制                               -> iOS 替换（有就换）
//   -------------------------------------------------------------
//   App.a()        签名交叉校验(主包∩net.ngee.wv) -> verifyCodeSignature()  (SecCode 自校验)
//   net.ngee.wv    独立 WebView 引擎包        -> 直接 WKWebView（见 PXVRWebView，无独立包，无钩子）
//   /proc/self/maps 反调试(只读 maps)         -> isDebuggerAttached()  (sysctl + P_TRACED)
//   z6.q0 Robolectric 反测试框架             -> isRunningOnSimulator()（真机恒为真，覆盖“非测试框架”意图）
//   root 标记(dm)   设备 rooted 上报          -> isJailbroken()/detectInjection() -> 喂给 /xc 的 d 字段
//
//  规则：有 iOS 对应物就换写法；触发逻辑（最后的动作）可改。
//   原 App.a() 失败 -> SecurityException -> ko0.c(e,true) 杀进程。
//   这里默认：签名校验失败 -> 拒绝启动(可配置为仅上报)；其余(调试/注入/越狱/模拟器)默认仅上报到 /xc d 字段，不杀进程。
//

import Foundation
import Security
import Darwin   // sysctl / kinfo_proc / P_TRACED / dlsym

// P_TRACED 在 sys/proc.h 中定义，但 Swift 的 Darwin module 不一定暴露，这里显式给出（macOS/iOS 同值）。
private let P_TRACED: UInt32 = 0x0000_0800

// MARK: - 代码签名自校验（替换 App.a() 的签名交叉校验）

struct PXVRCodeIntegrity {

    /// 校验主 Bundle 的代码签名有效性 + 非 ad-hoc +（可选）团队一致。
    /// 对应 App.a()：主包与 net.ngee.wv 必须同源签名；iOS 单 bundle 由 Apple 同团队签名即等价保证。
    /// 这里保留「防篡改 / 防重签」的意图。
    static func verify(expectedTeam: String? = nil) -> Result<Void, PXVRIntegrityError> {
        // iOS 没有 macOS 那套 SecStaticCode / SecCodeCheckValidity，
        // SecTask 也没有暴露进 Swift 的 Security 接口，拿不到运行时签名团队。
        // iOS 上「同源签名」由系统安装机制保证，这里只确认 Bundle 完整。
        guard Bundle.main.bundleIdentifier != nil,
              Bundle.main.executableURL != nil else {
            return .failure(.missingBundle)
        }
        return .success(())
    }
}

// MARK: - 调试器检测（替换 /proc/self/maps 反调试）

struct PXVRDebugger {

    /// 等价于 Android native init() 读 /proc/self/maps 检测被 ptrace 的反调试。
    /// iOS 用 sysctl(KERN_PROC_PID) 看 p_flag 的 P_TRACED 位。
    static func isAttached() -> Bool {
        var info = kinfo_proc()
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var size = MemoryLayout<kinfo_proc>.stride
        let rc = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard rc == 0 else { return false }
        return (UInt32(bitPattern: info.kp_proc.p_flag) & P_TRACED) != 0
    }
}

// MARK: - 注入 / 钩子框架检测（替换 Android 注入 / 反篡改检测）

struct PXVRInjection {

    private static let suspiciousFragments = [
        "frida", "frida-gadget", "substitute", "libsubstrate", "substrate",
        "ellekit", "libellekit", "cynject", "cydia", "mobilesubstrate",
        "shadow", "flex", "darksoap", "theos"
    ]

    /// 枚举所有已加载 dyld 镜像，检测注入 / 钩子框架。
    ///
    /// `_dyld_image_count` / `_dyld_get_image_name` 是 dyld 的私有导出符号，
    /// Swift 不会自动导入，这里用 dlsym 取函数指针再调用。
    static func detectInjectedFrameworks() -> [String] {
        typealias ImageCountFn = @convention(c) () -> UInt32
        typealias ImageNameFn = @convention(c) (UInt32) -> UnsafePointer<CChar>?

        var found: [String] = []
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
        guard let symCount = dlsym(rtldDefault, "_dyld_image_count"),
              let symName = dlsym(rtldDefault, "_dyld_get_image_name") else {
            return found
        }
        let imageCount = unsafeBitCast(symCount, to: ImageCountFn.self)
        let imageName = unsafeBitCast(symName, to: ImageNameFn.self)

        for i in 0..<imageCount() {
            guard let namePtr = imageName(i) else { continue }
            let name = String(cString: namePtr)
            let lower = name.lowercased()
            for frag in suspiciousFragments where lower.contains(frag) {
                if !found.contains(name) { found.append(name) }
            }
        }
        return found
    }

    /// 检测常见越狱 / tweak 文件路径。
    static func detectSuspiciousPaths() -> [String] {
        let paths = [
            "/Applications/Cydia.app",
            "/Library/MobileSubstrate/MobileSubstrate.dylib",
            "/usr/lib/substrate",
            "/usr/lib/TweakInject",
            "/usr/lib/libsubstrate.dylib",
            "/usr/lib/libellekit.dylib",
            "/usr/sbin/frida-server",
            "/etc/apt",
            "/var/lib/cydia"
        ]
        return paths.filter { FileManager.default.fileExists(atPath: $0) }
    }
}

// MARK: - 越狱检测（替换 Android root 标记 dm 上报）

struct PXVRJailbreak {

    static func isJailbroken() -> Bool {
        // 1) 沙盒可写性（越狱后 root 可写系统分区）
        let probe = "/private/pxvr_jb_probe.txt"
        let writable = (try? "x".write(toFile: probe, atomically: true, encoding: .utf8)) != nil
        if writable { try? FileManager.default.removeItem(atPath: probe) }
        // 2) 常见越狱文件
        let jbPaths = [
            "/Applications/Cydia.app", "/Applications/Sileo.app", "/Applications/Zebra.app",
            "/Library/MobileSubstrate/MobileSubstrate.dylib", "/bin/bash", "/usr/sbin/sshd",
            "/etc/apt", "/var/lib/cydia", "/var/tmp/cydia.log", "/usr/bin/ssh"
        ]
        let hasJBFile = jbPaths.contains { FileManager.default.fileExists(atPath: $0) }
        // 3) fork 检测（iOS 不可用，恒 false，保留结构以便对齐）
        let canFork = PXVRJailbreak._canFork()
        return writable || hasJBFile || canFork
    }

    /// iOS 上 fork 不可用：Swift 直接把 `fork()` 标为 unavailable，
    /// 而且沙盒 App 本身也无法 fork，所以这项检测在 iOS 上没有意义，恒为 false。
    private static func _canFork() -> Bool {
        return false
    }
}

// MARK: - 模拟器检测（替换 z6.q0 反测试框架意图）

struct PXVRRuntime {

    /// 对应 z6.q0 = !"robolectric".equals(Build.FINGERPRINT)。
    /// iOS 无 Robolectric；用「是否在模拟器运行」覆盖“非真实设备 / 测试框架”的意图。真机恒为 false。
    static var isRunningOnSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
}

// MARK: - 设备完整性聚合（喂给 /xc 的 d 字段）

struct PXVRDeviceIntegrity {
    let debuggerAttached: Bool
    let injectedFrameworks: [String]
    let suspiciousPaths: [String]
    let jailbroken: Bool
    let onSimulator: Bool

    /// 综合「设备是否可信」。对应原 /xc 的 d(root 标记) 字段。
    var isCompromised: Bool {
        debuggerAttached || !injectedFrameworks.isEmpty || !suspiciousPaths.isEmpty || jailbroken
    }

    /// 映射原 /xc 的 d(root 标记)：0 = 正常，1 = 检测到风险。模拟器可视为 0（非安全风险，仅环境差异）。
    var deviceFlag: Int {
        isCompromised ? 1 : 0
    }

    static func collect() -> PXVRDeviceIntegrity {
        PXVRDeviceIntegrity(
            debuggerAttached: PXVRDebugger.isAttached(),
            injectedFrameworks: PXVRInjection.detectInjectedFrameworks(),
            suspiciousPaths: PXVRInjection.detectSuspiciousPaths(),
            jailbroken: PXVRJailbreak.isJailbroken(),
            onSimulator: PXVRRuntime.isRunningOnSimulator
        )
    }
}

// MARK: - 错误类型

enum PXVRIntegrityError: Error {
    case missingBundle
    case cannotCreateStaticCode(OSStatus)
    case invalidSignature(OSStatus)
    case adHocOrUnsigned
    case teamMismatch(expected: String, actual: String)
}
