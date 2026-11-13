//
//  WebController.swift
//  PXVRUI
//
//  持有 WKWebView 与 Sensei 桥，负责状态回传和日志收集。
//

import Foundation
import SwiftUI
import UIKit
import WebKit

final class WebController: NSObject, ObservableObject {

    @Published var logs: [String] = []
    @Published var currentURL: String = ""
    @Published var pageTitle: String = ""
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isConnecting = false
    @Published var lastConfig: [String: Any] = [:]

    let bridge = PXVRWebBridge()
    private(set) var webView: WKWebView!

    private let maxLogs = 120

    override init() {
        super.init()

        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.websiteDataStore = .default()

        bridge.log = { [weak self] line in
            DispatchQueue.main.async { self?.append(line) }
        }
        // 桥必须在 WKWebView 创建之前装进 configuration
        bridge.install(into: cfg)

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsLinkPreview = true

        bridge.webView = wv
        bridge.delegate = self
        webView = wv

        PXVRLogger.sink = { [weak self] line in
            DispatchQueue.main.async { self?.append(line) }
        }

        append("[app] 就绪，桥已安装")
    }

    // MARK: 动作

    func load(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: normalized) else {
            append("[app] 地址非法: \(trimmed)")
            return
        }
        append("[app] 打开 \(url.absoluteString)")
        webView.load(URLRequest(url: url))
    }

    /// 完整握手：/xk 拿设备 key → /xc 上报 → 读下发的主页面地址并加载
    func connect(server: String) {
        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: normalized) else {
            append("[net] 服务器地址非法: \(trimmed)")
            return
        }
        guard !isConnecting else { return }

        isConnecting = true
        append("[net] 开始握手 \(url.absoluteString)")

        Task {
            let result = await PXVRNetwork.shared.handshake(baseURL: url)

            await MainActor.run {
                self.isConnecting = false
                self.lastConfig = result.config ?? [:]
                if let cfg = result.config {
                    self.append("[net] 配置字段: \(cfg.keys.sorted().joined(separator: ", "))")
                }
                if let page = result.page, let pageURL = URL(string: page) {
                    self.append("[net] 加载主页面: \(page)")
                    self.address = page
                    self.webView.load(URLRequest(url: pageURL))
                } else {
                    self.append("[net] 握手结束但没有下发主页面（mp/hp 为空）")
                }
            }
        }
    }

    func goBack() { if webView.canGoBack { webView.goBack() } }
    func goForward() { if webView.canGoForward { webView.goForward() } }
    func reload() { webView.reload() }

    func clearLogs() { logs.removeAll() }

    // MARK: 日志

    func append(_ line: String) {
        let stamp = Self.formatter.string(from: Date())
        logs.append("\(stamp) \(line)")
        if logs.count > maxLogs { logs.removeFirst(logs.count - maxLogs) }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func syncState() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        currentURL = webView.url?.absoluteString ?? currentURL
        pageTitle = webView.title ?? ""
    }
}

// MARK: - 导航

extension WebController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        append("[web] 开始加载 \(webView.url?.absoluteString ?? "?")")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        syncState()
        append("[web] 完成 \(webView.url?.absoluteString ?? "?")")
        bridge.push("route", ["url": webView.url?.absoluteString ?? ""])
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        append("[web] 失败 \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        isLoading = false
        append("[web] 预加载失败 \(error.localizedDescription)")
    }
}

// MARK: - 页面弹窗

extension WebController: WKUIDelegate {

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
        append("[web] alert: \(message)")
        completionHandler()
    }
}

// MARK: - 桥的接收方

extension WebController: PXVRWebBridgeDelegate {

    func webBridge(_ bridge: PXVRWebBridge,
                   perform call: PXVRWebCall,
                   reply: @escaping (Any?) -> Void) {
        append("[bridge] \(call.api.rawValue)(\(call.args))")

        switch call.api {
        case .shiroko:
            // 占位：接下载/收藏列表
            reply([Any]())

        case .serika:
            if let s = call.args["url"] as? String, let url = URL(string: s) {
                UIApplication.shared.open(url)
            }
            reply(nil)

        case .plana:
            let page = call.args["page"] as? String ?? "pages/start.html"
            append("[bridge] 内置页请求: \(page)")
            reply(nil)

        case .hoshino:
            append("[bridge] UI 切换: \(call.args["state"] ?? "nil")")
            reply(nil)

        case .neru, .karin:
            reply(nil)

        default:
            reply(nil)
        }
    }
}
