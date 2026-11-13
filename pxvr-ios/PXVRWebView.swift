//
//  PXVRWebView.swift
//  PXVR-iOS
//
//  App 的网页宿主。iOS 直接用系统 WKWebView 渲染 Pixiv 网页，
//  不再需要原版那种「独立 WebView 引擎包 + 升级校验」。
//
//  桥接一律走 PXVRWebBridge：注入垫片、双向消息、路由与错误回传。
//

import WebKit

final class PXVRWebView: NSObject {
    static let shared = PXVRWebView()

    private(set) var bridge = PXVRWebBridge()
    private var webView: WKWebView?

    /// 对外转发网页消息
    var delegate: PXVRWebBridgeDelegate? {
        get { bridge.delegate }
        set { bridge.delegate = newValue }
    }

    /// 准备 WKWebView。重复调用是安全的。
    func prepare() {
        guard webView == nil else { return }

        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        // 与 Android 版一致：允许页面与原生互相访问，Cookie 走共享存储
        cfg.websiteDataStore = .default()

        // 桥必须在创建 WKWebView 之前装进 configuration
        bridge.log = { PXVRLogger.warning($0) }
        bridge.install(into: cfg)

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.customUserAgent = PXVRRequestProfile.userAgent
        wv.allowsBackForwardNavigationGestures = true
        wv.navigationDelegate = self
        wv.uiDelegate = self

        webView = wv
        bridge.webView = wv

        PXVRLogger.info("WKWebView 已就绪，注入桥已安装")
    }

    /// 加载 Pixiv 网页（登录页 / 作品页等）。
    func load(url: URL) {
        prepare()
        webView?.load(URLRequest(url: url))
    }

    /// 供 SwiftUI / UIKit 挂载的视图。
    var view: WKWebView? { webView }

    /// 主动通知网页某个原生事件。
    func notify(_ name: String, _ payload: [String: Any] = [:]) {
        bridge.push(name, payload)
    }

    /// 让网页执行一段脚本（调试用）。
    func evaluate(_ js: String) {
        bridge.evaluate(js)
    }
}

// MARK: - WKNavigationDelegate

extension PXVRWebView: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        PXVRLogger.debug("[web] 开始加载 \(webView.url?.absoluteString ?? "?")")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        PXVRLogger.debug("[web] 加载完成 \(webView.url?.absoluteString ?? "?")")
        // 页面每次加载完都补一条 route，兜住垫片未触发的场景
        bridge.push("route", ["url": webView.url?.absoluteString ?? ""])
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        PXVRLogger.warning("[web] 加载失败: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        PXVRLogger.warning("[web] 预加载失败: \(error.localizedDescription)")
    }
}

// MARK: - WKUIDelegate

extension PXVRWebView: WKUIDelegate {

    /// 页面里的 target=_blank / window.open 一律在当前 WebView 内打开，
    /// 避免弹出系统浏览器把用户踢出 App。
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        PXVRLogger.info("[web] alert: \(message)")
        completionHandler()
    }
}
