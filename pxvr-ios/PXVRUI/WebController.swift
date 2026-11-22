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

    @Published var logs: [LogLine] = []
    @Published var currentURL: String = ""
    @Published var pageTitle: String = ""
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isConnecting = false
    @Published var lastConfig: [String: Any] = [:]

    var logText: String { logs.map(\.text).joined(separator: "\n") }

    func exportLogURL() -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pxvr-log-\(Int(Date().timeIntervalSince1970)).txt")
        do { try logText.write(to: url, atomically: true, encoding: .utf8); return url }
        catch { return nil }
    }
    /// 登录状态持久化（原版也存在本地，重启后仍是已登录）
    @Published var isLoggedIn: Bool = UserDefaults.standard.bool(forKey: "pxvr.loggedIn") {
        didSet { UserDefaults.standard.set(isLoggedIn, forKey: "pxvr.loggedIn") }
    }

    /// 最近一次请求的真实地址（webView.url 是代理地址，不能复用）
    private var lastRequested: String = ""
    /// 握手成功的那台服务器
    private(set) var activeServer: URL?

    let bridge = PXVRWebBridge()
    private(set) var webView: WKWebView!

    private let maxLogs = 120
    /// 自增序号，保证每行 id 稳定（原来用 offset，裁剪缓冲区后会错位导致崩溃）
    private var logSeq = 0

    struct LogLine: Identifiable {
        let id: Int
        let text: String
    }

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

    /// 统一成 https：服务器只提供 TLS，http 会被 ATS 直接拦下。
    private static func forceHTTPS(_ raw: String) -> String {
        var s = raw
        if !s.contains("://") { s = "https://" + s }
        if s.lowercased().hasPrefix("http://") {
            s = "https://" + String(s.dropFirst("http://".count))
        }
        return s
    }


    func load(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normalized = Self.forceHTTPS(trimmed)
        guard let url = URL(string: normalized) else {
            append("[app] 地址非法: \(trimmed)")
            return
        }
        lastRequested = normalized
        // 一律走本地代理：iOS 无法像 Android 那样劫持 WebView 代理，
        // 只能把目标 URL 编码进路径。
        PXVRProxyServer.shared.start()
        openThroughProxy(url, attempt: 0)
    }

    /// 代理是异步就绪的，第一次调用可能还没拿到端口，稍等重试
    private func openThroughProxy(_ url: URL, attempt: Int) {
        if let proxyURL = PXVRProxyServer.shared.entryURL(for: url.absoluteString) {
            append("[proxy] 经本地代理打开 \(proxyURL.absoluteString)")
            webView.load(URLRequest(url: proxyURL))
            return
        }
        if attempt < 8 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.openThroughProxy(url, attempt: attempt + 1)
            }
        } else {
            append("[proxy] 代理未就绪，直连打开")
            webView.load(URLRequest(url: url))
        }
    }

    /// 完整握手：/xk 拿设备 key → /xc 上报 → 读下发的主页面地址并加载
    func connect(server: String, thenLoad address: String? = nil) {
        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = Self.forceHTTPS(trimmed)
        let url: URL? = trimmed.isEmpty ? nil : URL(string: normalized)
        if !trimmed.isEmpty && url == nil {
            append("[net] 服务器地址非法: \(trimmed)")
            return
        }
        guard !isConnecting else { return }

        isConnecting = true
        append("[net] 开始握手 \(url?.absoluteString ?? "（内置服务器列表）")")

        Task {
            // 用户填了就只试它；没填则用内置列表逐个试
            let servers: [URL]
            if let provided = url {
                servers = [provided]
            } else {
                servers = PXVRServerList.candidates.compactMap { URL(string: "https://" + $0) }
            }
            let result = await PXVRNetwork.shared.handshake(servers: servers)

            await MainActor.run {
                self.isConnecting = false
                self.lastConfig = result.config ?? [:]
                if let cfg = result.config {
                    self.append("[net] 配置字段: \(cfg.keys.sorted().joined(separator: ", "))")
                }
                if let base = result.base {
                    self.append("[net] 使用服务器: \(base.absoluteString)")
                    self.activeServer = base
                }
                // 把 /xc 下发的配置交给路由表，代理才知道每个域名走哪个节点
                if let cfg = result.config, !cfg.isEmpty {
                    PXVRProxyServer.shared.loadConfig(cfg)
                    self.append("[proxy] 路由配置已更新（\(cfg.count) 字段）")
                }
                if let page = result.page, let pageURL = URL(string: page) {
                    self.append("[net] 加载主页面: \(page)")
                    self.webView.load(URLRequest(url: pageURL))
                } else if let addr = address, result.base != nil {
                    // 服务端没下发主页面：配置已就位，直接打开传入的地址
                    self.append("[net] 握手完成，打开 \(addr)")
                    self.load(addr)
                } else {
                    self.append("[net] 握手结束但没有下发主页面（mp/hp 为空）")
                }
            }
        }
    }

    /// 登录：需先握手拿到设备 key 和可用服务器
    func login(email: String, password: String, action: String = "l") {
        guard let base = activeServer else {
            append("[login] 还没有可用服务器，先点「连接」")
            return
        }
        guard !email.isEmpty, !password.isEmpty else {
            append("[login] 邮箱或密码为空")
            return
        }
        append("[login] 提交 \(action == "l" ? "登录" : "注册") \(email)")
        Task {
            let resp = await PXVRNetwork.shared.login(
                baseURL: base, email: email, password: password, action: action)
            guard let r = resp else {
                await MainActor.run { self.append("[login] 失败（见上方 /um 响应）") }
                return
            }
            // r=0 成功；r=-1 且带「已登录」= 这个设备 key 本来就有有效会话（不用重复登录）
            let code = (r["r"] as? Int) ?? (r["r"] as? String).flatMap(Int.init) ?? -99
            let msg = (r["m"] as? String) ?? ""
            let alreadyIn = msg.contains("已登录")
            guard code == 0 || (code == -1 && alreadyIn) else {
                await MainActor.run { self.append("[login] 服务器返回 r=\(code) \(msg)，登录失败") }
                return
            }
            await MainActor.run {
                self.append(alreadyIn ? "[login] 该设备已有会话（已登录）" : "[login] 登录成功")
                self.isLoggedIn = true
            }
            // 登录后再拉一次 /xc：完整配置（含 pixiv 全部主机 + ralt）只有登录后才下发。
            // await 必须在 MainActor.run 之外，否则闭包是同步的，编译不过。
            if let cfg = await PXVRNetwork.shared.performXC(baseURL: base) {
                await MainActor.run {
                    PXVRProxyServer.shared.loadConfig(cfg)
                    self.append("[proxy] 登录后配置刷新：\(cfg.count) 字段，ph=\(cfg["ph"] ?? "?")，ralt=\(cfg["ralt"] ?? "?")")
                    // 配置到位后重开当前页面，之前 502 的那次会重试成功
                    self.load(self.lastRequested.isEmpty ? "https://www.pixiv.net" : self.lastRequested)
                }
            }
        }
    }

    /// 退出登录（原版：退出后清本地账号状态，不影响会员时长）
    func logout() {
        isLoggedIn = false
        PXVRKeychain.clear()
        PXVRNetwork.clearStoredKey()
        append("[login] 已退出登录")
    }

    /// 桌面版 / 移动版切换
    func toggleDesktopMode() {
        let ua = webView.customUserAgent
        if ua == nil || !ua!.contains("Macintosh") {
            webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
            append("[web] 已切换桌面版")
        } else {
            webView.customUserAgent = nil
            append("[web] 已切换移动版")
        }
        webView.reload()
    }

    func goBack() { if webView.canGoBack { webView.goBack() } }
    func goForward() { if webView.canGoForward { webView.goForward() } }
    func reload() { webView.reload() }

    func clearLogs() { logs.removeAll() }

    // MARK: 日志

    func append(_ line: String) {
        let stamp = Self.formatter.string(from: Date())
        logSeq += 1
        logs.append(LogLine(id: logSeq, text: "\(stamp) \(line)"))
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

    /// 等价替代 Android 的透明代理：
    /// 页面里 JS 改 location、提交表单、点没被改写的链接时，WebView 会去请求真实域名。
    /// 这里全部拦下来，改走本地代理重新加载。
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let s = url.absoluteString

        // 已经是代理地址 → 放行
        if s.hasPrefix("http://127.0.0.1") || s.hasPrefix("https://127.0.0.1") {
            decisionHandler(.allow)
            return
        }

        // 普通网页请求 → 取消并改走代理
        if url.scheme == "http" || url.scheme == "https" {
            decisionHandler(.cancel)
            append("[web] 接管导航 \(s.prefix(80))")
            load(s)
            return
        }

        // tel: / mailto: / itms-apps: 等交给系统
        decisionHandler(.allow)
    }


    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        append("[web] 开始加载 \(webView.url?.absoluteString ?? "?")")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        syncState()
        append("[web] 完成 \(webView.url?.absoluteString ?? "?")")
        bridge.push("route", ["url": webView.url?.absoluteString ?? ""])

        // 记录浏览历史（对应原版 ObjectBox 的 History）
        let real = lastRequested
        if real.hasPrefix("http"), !real.contains("127.0.0.1") {
            let title = pageTitle
            let item = HistoryItem(title: title, url: real)
            DataManager.shared.addHistory(item)
        }
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
