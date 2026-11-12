//
//  PXVRWebView.swift
//  PXVR-iOS
//
//  替换 net.ngee.wv 的「独立 WebView 引擎包 + WebViewUpgrade 钩子系统 WebView」：
//  iOS 直接用系统 WKWebView 渲染 Pixiv 网页（登录 / 浏览），无需独立分发包，
//  也无需跨包签名校验（App.a() 的同源签名检查在 iOS 上由 Apple 同团队签名天然保证）。
//

import WebKit

final class PXVRWebView {
    static let shared = PXVRWebView()

    private var webView: WKWebView?

    /// 准备 WKWebView（对应 App.onCreate 中的 WebViewUpgrade.upgrade(net.ngee.wv)）。
    func prepare() {
        let cfg = WKWebViewConfiguration()
        // 按需：注入脚本、自定义 UA、处理 Pixiv 登录回调、Cookie 同步等
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.customUserAgent = "PXVR-iOS"
        wv.allowsBackForwardNavigationGestures = true
        self.webView = wv
        PXVRLogger.info("WKWebView 已就绪（替代 net.ngee.wv）")
    }

    /// 加载 Pixiv 网页（登录页 / 作品页等）。
    func load(url: URL) {
        webView?.load(URLRequest(url: url))
    }

    /// 供 SwiftUI/UIKit 挂载的视图。
    var view: WKWebView? { webView }
}
