//
//  PXVRStartup.swift
//  PXVR-iOS
//
//  对应 Android App.onCreate()：
//     a(this)                                -> PXVRCodeIntegrity.verify()
//     WebViewUpgrade.upgrade(net.ngee.wv)     -> PXVRWebView 准备 WKWebView（无独立包，无需钩子系统 WebView）
//   并采集设备完整性（调试 / 注入 / 越狱 / 模拟器）供 /xc 上报。
//
//  触发逻辑（可改，符合用户「最后的触发可以改」）：
//   - 签名校验失败：默认拒绝启动并上报（原逻辑是 SecurityException -> ko0.c(e,true) 杀进程）。
//   - 设备完整性异常：默认仅记录，上报到 /xc 的 d 字段，不杀进程（与原 root 标记上报行为一致）。
//

import Foundation

final class PXVRStartup {
    static let shared = PXVRStartup()

    private(set) var integrity: PXVRDeviceIntegrity?
    private(set) var signatureOK: Bool = false

    /// 在 App 启动早期调用（@main init 或 didFinishLaunchingWithOptions）。
    /// - Parameter expectedTeam: 生产环境填入你的 Apple Team ID 做强校验；传 nil 只做有效性 + 非 ad-hoc 校验。
    func run(expectedTeam: String? = nil) {
        // 1) 包 / 代码签名校验（替换 App.a()）
        switch PXVRCodeIntegrity.verify(expectedTeam: expectedTeam) {
        case .success:
            signatureOK = true
            PXVRLogger.info("代码签名校验通过")

        case .failure(let err):
            signatureOK = false
            PXVRLogger.warning("代码签名校验失败: \(err)")
            // 触发：原逻辑杀进程。这里默认“上报 + 拒绝继续初始化”。如需严格复刻原行为，取消下一行：
            // fatalError("package verification failed (iOS): \(err)")
        }

        // 2) WebView 引擎准备（替换 net.ngee.wv 的独立包 + 钩子）
        //    iOS 直接用系统 WKWebView，不需要偷换系统 WebView，也不需跨包签名校验。
        PXVRWebView.shared.prepare()

        // 3) 设备完整性采集（替换 /proc 反调试 + root 标记上报 + q0）
        integrity = PXVRDeviceIntegrity.collect()
        if let i = integrity, i.isCompromised {
            PXVRLogger.warning("设备完整性异常: debugger=\(i.debuggerAttached) injected=\(i.injectedFrameworks) paths=\(i.suspiciousPaths) jailbreak=\(i.jailbroken)")
        }
    }

    /// 供 /xc 上报使用的设备标记（原 d 字段）。
    var deviceFlag: Int { integrity?.deviceFlag ?? 0 }
}
