//
//  PXVRURLProtocol.swift
//  PXVRUI
//
//  进程内拦截 WKWebView 的 http(s) 请求 —— 对应原版 Android 的进程级代理。
//
//  做法：
//    1. URLProtocol.registerClass + 私有 API
//       WKBrowsingContextController.registerSchemeForCustomProtocol("https")
//    2. 本类收到原始请求（URL 完全没被改写）
//    3. 按 Host 查路由表 → 明文 HTTP 发到节点（和原版一致）
//    4. 把响应原样交回 WebKit，并把 Set-Cookie 同步进 WKHTTPCookieStore
//
//  只影响本 App，不碰系统代理。
//

import Foundation
import WebKit

final class PXVRURLProtocol: URLProtocol {

    private var worker: Task<Void, Never>?

    // MARK: - 注册

    /// 是否启用：与设置页的通道选择保持一致（唯一真源是 pxvr.channel）
    static var enabled: Bool {
        get { PXVRChannel.current == .hook }
        set { PXVRChannel.current = newValue ? .hook : .rewrite }
    }

    /// 注册是否真的执行成功（供设置页显示）
    private(set) static var installed = false

    static func install() {
        URLProtocol.registerClass(PXVRURLProtocol.self)

        // 私有 API：让 WKWebView 把 https 也交给我们
        guard let raw = NSClassFromString("WKBrowsingContextController") else {
            PXVRLogger.warning("[hook] 找不到 WKBrowsingContextController")
            return
        }
        let cls = raw as AnyObject
        let sel = NSSelectorFromString("registerSchemeForCustomProtocol:")
        guard cls.responds(to: sel) else {
            PXVRLogger.warning("[hook] registerSchemeForCustomProtocol 不可用")
            return
        }
        _ = cls.perform(sel, with: "http" as NSString)
        _ = cls.perform(sel, with: "https" as NSString)
        installed = true
        PXVRLogger.info("[hook] 已注册 scheme 拦截")
    }

    /// 探测私有 API 在系统里的真实状态：存在性、是否响应、注册是否抛异常
    static func probe() {
        guard let raw = NSClassFromString("WKBrowsingContextController") else {
            PXVRLogger.warning("[probe] WKBrowsingContextController 不存在")
            return
        }
        let cls = raw as AnyObject
        let sel = NSSelectorFromString("registerSchemeForCustomProtocol:")
        let exists = cls.responds(to: sel)
        PXVRLogger.info("[probe] 类存在=是 方法响应=\(exists ? "是" : "否")")

        // 真正调用一次，看系统是否直接忽略或抛异常
        if exists {
            _ = cls.perform(sel, with: "https" as NSString)
            PXVRLogger.info("[probe] 已尝试注册 https，观察后续请求是否进本类")
        }

        // 另一条：WKURLSchemeHandler 能不能接 https
        // 注意不能直接 setURLSchemeHandler(https)——被占用的 scheme 会抛 ObjC 异常，
        // Swift 接不住会直接崩。用 handlesURLScheme 判断即可。
        let native = WKWebView.handlesURLScheme("https")
        PXVRLogger.info("[probe] WebKit 原生处理 https=\(native ? "是（URLSchemeHandler 无法接管）" : "否")")
    }

    // MARK: - URLProtocol

    /// 只拦这些域；其余（含我们自己的 API 域名）一律放行，
    /// 否则 URLProtocol.registerClass 会把 PXVRNetwork 的请求也拦下来造成递归。
    private static let hosts = [
        "pixiv.net", "pximg.net", "pixiv.org", "fanbox.cc",
        "pixivision.net", "pixivsketch.net",
    ]

    override class func canInit(with request: URLRequest) -> Bool {
        guard enabled,
              let scheme = request.url?.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = request.url?.host?.lowercased() else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        PXVRLogger.info("[hook] 拦截到 " + (request.url?.absoluteString ?? ""))

        let method = request.httpMethod ?? "GET"
        var path = url.path.isEmpty ? "/" : url.path
        if let q = url.query { path += "?" + q }

        // 组头
        var headers: [String: String] = [:]
        for (k, v) in request.allHTTPHeaderFields ?? [:] {
            let lk = k.lowercased()
            if lk == "accept-encoding" || lk == "content-length" { continue }
            headers[k] = v
        }
        headers["Host"] = host
        headers["Accept-Encoding"] = "identity"
        headers["Connection"] = "close"
        if headers["Referer"] == nil { headers["Referer"] = "https://www.pixiv.net/" }

        // WebKit 不会给自定义 scheme 的请求带 Cookie，必须自己补
        let cookieHeader = awaitCookieHeader(url: url)
        let body = Self.bodyData(of: request)
        let port = UInt16(url.port ?? (url.scheme == "https" ? 443 : 80))

        worker = Task { [weak self] in
            guard let self = self else { return }
            // WebKit 不会给自定义 scheme 的请求带 Cookie，必须自己补
            var hdrs0 = headers
            let ck = await self.cookieHeader(for: url)
            if !ck.isEmpty { hdrs0["Cookie"] = ck }

            let chain = PXVRProxyServer.shared.router.chain(for: host)
            var resp: PXVRRawHTTP.Response?
            var lastError: Error?

            // 沿路由链逐个试：第一个节点常年挂起，不能只打一个
            for route in chain {
                var h = hdrs0
                if let n = route.headerName, let v = route.headerValue { h[n] = v }
                do {
                    let r = try await PXVRRawHTTP.request(
                        host: route.host, port: UInt16(route.port),
                        method: method, path: path, headers: h, body: body)
                    PXVRLogger.info("[hook] \(host) → \(route.address) \(r.status) \(r.body.count)B")
                    resp = r
                    break
                } catch {
                    PXVRLogger.warning("[hook] \(host) 经 \(route.address) 失败：\(error.localizedDescription)")
                    lastError = error
                    // 记进路由表冷却，下次这条链就不再先打它
                    PXVRProxyServer.shared.router.markFailed(route.address)
                }
            }

            do {
                guard let resp = resp else { throw lastError ?? URLError(.cannotConnectToHost) }

                await self.syncCookies(resp.headerList, url: url)

                // 保留 Content-Encoding：body 是按原样拿到的，删了头会导致乱码
                var hdrs: [String: String] = [:]
                for (k, v) in resp.headerList {
                    let lk = k.lowercased()
                    if lk == "transfer-encoding" || lk == "connection"
                        || lk == "content-length" || lk == "set-cookie" { continue }
                    hdrs[k] = v
                }
                hdrs["Content-Length"] = String(resp.body.count)

                guard let http = HTTPURLResponse(url: url, statusCode: resp.status,
                                                 httpVersion: "HTTP/1.1", headerFields: hdrs) else {
                    self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                    return
                }
                self.client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
                if !resp.body.isEmpty {
                    self.client?.urlProtocol(self, didLoad: resp.body)
                }
                self.client?.urlProtocolDidFinishLoading(self)
            } catch {
                self.client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {
        worker?.cancel()
        worker = nil
    }

    // MARK: - 工具

    /// WKWebView 的 POST 体在 httpBodyStream 里，不在 httpBody
    private static func bodyData(of request: URLRequest) -> Data? {
        if let b = request.httpBody { return b }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buf = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: size)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        return data.isEmpty ? nil : data
    }

    /// 把响应的 Set-Cookie 写进 WebKit，否则登录态存不住
    /// 从 WebKit 的 cookie 存储里取出该 URL 适用的 cookie，拼成请求头
    private func cookieHeader(for url: URL) async -> String {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let all: [HTTPCookie] = await withCheckedContinuation { cont in
            store.getAllCookies { cont.resume(returning: $0) }
        }
        let host = url.host?.lowercased() ?? ""
        let matched = all.filter { c in
            var d = c.domain.lowercased()
            if d.hasPrefix(".") { d = String(d.dropFirst()) }
            return host == d || host.hasSuffix("." + d)
        }
        guard !matched.isEmpty else { return "" }
        return matched.map { $0.name + "=" + $0.value }.joined(separator: "; ")
    }

    /// 响应里每一条 Set-Cookie 分别写进 WebKit（多值头必须逐条处理）
    private func syncCookies(_ headers: [(String, String)], url: URL) async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        for (k, v) in headers where k.lowercased() == "set-cookie" {
            let parts = v.components(separatedBy: ";")
            guard let first = parts.first else { continue }
            let kv = first.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }

            var props: [HTTPCookiePropertyKey: Any] = [
                .name: kv[0].trimmingCharacters(in: .whitespaces),
                .value: kv[1].trimmingCharacters(in: .whitespaces),
            ]
            var domain = url.host ?? ""
            for attr in parts.dropFirst() {
                let seg = attr.trimmingCharacters(in: .whitespaces)
                let low = seg.lowercased()
                if low.hasPrefix("domain=") {
                    domain = String(seg.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                } else if low.hasPrefix("path=") {
                    props[.path] = String(seg.dropFirst(5))
                } else if low == "secure" {
                    props[.secure] = "TRUE"
                }
            }
            if !domain.isEmpty { props[.domain] = domain }
            if props[.path] == nil { props[.path] = "/" }

            if let c = HTTPCookie(properties: props) {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    store.setCookie(c) { cont.resume() }
                }
            }
        }
    }
}
