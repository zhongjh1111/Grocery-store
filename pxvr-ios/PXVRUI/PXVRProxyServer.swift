//
//  PXVRProxyServer.swift
//  PXVRUI
//
//  本地 HTTP 代理。
//
//  为什么需要它：原版 Android 靠反射劫持 WebView 的 ProxyChangeListener，
//  把页面流量导向自己的本地服务（见 w60.startProxyServer）。iOS 没有这个后门，
//  所以改成「URL 编码」方案：
//
//      WKWebView 请求 http://127.0.0.1:<port>/https://www.pixiv.net/xxx
//      代理解出真实 URL → 抓取 → 回写
//
//  返回 HTML 时把页面里的绝对/根相对链接改写成同样的 /https://... 形式，
//  这样后续资源请求也会回到代理。
//

import Foundation
import Network

final class PXVRProxyServer {

    static let shared = PXVRProxyServer()

    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private let queue = DispatchQueue(label: "pxvr.proxy")
    private let router = PXVRRouter()

    /// 用 /xc 下发的配置重建路由表
    func loadConfig(_ config: [String: Any]) {
        router.load(config)
        PXVRLogger.info("[proxy] 路由表已载入：精确 \(router.exact.count) 条 / 正则 \(router.patterns.count) 条 / 节点组 \(router.groups.count) 组")
    }

    /// 允许所有证书（对齐原版 TrustManager 空实现）
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 25
        cfg.httpShouldSetCookies = true
        cfg.httpCookieAcceptPolicy = .always
        return URLSession(configuration: cfg, delegate: PermissiveDelegate(), delegateQueue: nil)
    }()

    var isRunning: Bool { listener != nil && port > 0 }

    /// 给 WebView 用的入口地址
    /// 用 `/p?u=<编码>` 而不是 `/https://...`：后者会被浏览器按页面 base 再解析一次，
    /// 变成 `https://127.0.0.1:<port>/https://...`，代理就会去抓自己。
    func entryURL(for target: String) -> URL? {
        guard port > 0, let path = Self.proxyPath(target) else { return nil }
        return URL(string: "http://127.0.0.1:\(port)\(path)")
    }

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // 只绑回环：安全，且和原版一致
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)

            let l: NWListener
            do {
                l = try NWListener(using: params)
            } catch {
                PXVRLogger.warning("[proxy] 回环绑定失败，改用任意地址")
                l = try NWListener(using: .tcp, on: .any)
            }
            l.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.port = l.port?.rawValue ?? 0
                    PXVRLogger.info("[proxy] 监听 127.0.0.1:\(self?.port ?? 0)")
                case .failed(let e):
                    PXVRLogger.warning("[proxy] 启动失败: \(e)")
                    self?.listener = nil
                default:
                    break
                }
            }
            listener = l
            l.start(queue: queue)
        } catch {
            PXVRLogger.warning("[proxy] 无法监听: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }

    // MARK: - 连接处理

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, isDone, err in
            guard let self = self else { return }
            var buf = buffer
            if let c = chunk { buf.append(c) }

            if let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<headerEnd.lowerBound], as: UTF8.self)
                var body = Data(buf[headerEnd.upperBound...])
                self.dispatch(conn: conn, head: head, body: &body)
                return
            }
            if isDone || err != nil {
                conn.cancel()
                return
            }
            self.receive(conn, buffer: buf)
        }
    }

    private func dispatch(conn: NWConnection, head: String, body: inout Data) {
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { conn.cancel(); return }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { conn.cancel(); return }
        let method = String(parts[0])
        let rawPath = String(parts[1])

        // 从路径里解出真实 URL
        guard let target = Self.decodeTarget(rawPath) else {
            respond(conn, status: 400, reason: "Bad Request", mime: "text/plain", body: Data("bad target".utf8))
            return
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let idx = line.firstIndex(of: ":") {
                let k = String(line[..<idx]).trimmingCharacters(in: .whitespaces)
                let v = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }
        }
        headers["Host"] = nil

        PXVRLogger.info("[proxy] \(method) \(target.absoluteString.prefix(120))")

        // 按路由表走：命中节点就转发，否则直连；直连失败按 ralt 表回退
        // 没有主路由（如 #cf 直连）就直接用备路由，省掉一次必然失败的直连等待
        let host = target.host ?? ""
        let primary = router.route(for: host)
        let initial = primary ?? router.fallbackRoute(for: host)
        if primary == nil, let fb = initial {
            PXVRLogger.info("[proxy] 无主路由，直接用备路由 \(fb.address)")
        }
        fetch(conn: conn, target: target, method: method, body: body,
              clientHeaders: headers, route: initial,
              allowFallback: primary != nil)
    }

    /// 对应原版 lj0.c()：连节点、Host 留原站、加鉴权头。
    /// 走手写 HTTP/1.1（PXVRRawHTTP）：URLSession 会协商成 h2，
    /// 而 h2 用 :authority 表达主机，Host 头不参与路由 → 节点 302 死循环。
    private func fetch(conn: NWConnection, target: URL, method: String, body: Data,
                       clientHeaders: [String: String], route: PXVRRouter.Route?,
                       allowFallback: Bool) {
        guard let r = route else {
            fetchDirect(conn: conn, target: target, method: method, body: body,
                        contentType: clientHeaders["Content-Type"], allowFallback: allowFallback)
            return
        }

        let host = target.host ?? r.host
        var path = target.path.isEmpty ? "/" : target.path
        if let q = URLComponents(url: target, resolvingAgainstBaseURL: false)?.percentEncodedQuery,
           !q.isEmpty {
            path += "?" + q
        }

        var hdrs: [String: String] = [
            "Host": host,
            "User-Agent": Self.browserUA,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
            "Accept-Language": "ja,en;q=0.9",
            "Accept-Encoding": "identity",
            "Connection": "close",
        ]
        if let n = r.headerName, let v = r.headerValue { hdrs[n] = v }
        if let ct = clientHeaders["Content-Type"] { hdrs["Content-Type"] = ct }
        if let ck = clientHeaders["Cookie"] { hdrs["Cookie"] = ck }
        if let rf = clientHeaders["Referer"] { hdrs["Referer"] = rf }

        PXVRLogger.info("[proxy] 路由 \(host) → \(r.address)  (\(r.headerName ?? "直连IP"))")

        Task {
            do {
                let resp = try await PXVRRawHTTP.request(
                    host: r.host, port: UInt16(r.port), method: method, path: path,
                    headers: hdrs,
                    body: (method == "GET" || method == "HEAD") ? nil : body)

                PXVRLogger.info("[proxy] ← \(resp.status)  \(resp.body.count) 字节  \(host)\(path.prefix(30))")

                let mime = resp.headers["content-type"] ?? "application/octet-stream"
                var payload = resp.body
                if mime.contains("html") || mime.contains("css") {
                    if let text = String(data: payload, encoding: .utf8) {
                        payload = Data(Self.rewrite(text, base: target).utf8)
                    }
                }
                self.respond(conn, status: resp.status,
                             reason: resp.status == 200 ? "OK" : "Status",
                             mime: mime, body: payload)
            } catch {
                if allowFallback, let h = target.host, let fb = self.router.fallbackRoute(for: h) {
                    PXVRLogger.info("[proxy] 主路由失败，回退 \(fb.address)")
                    self.fetch(conn: conn, target: target, method: method, body: body,
                               clientHeaders: clientHeaders, route: fb, allowFallback: false)
                    return
                }
                PXVRLogger.warning("[proxy] 抓取失败: \(error.localizedDescription)")
                self.respond(conn, status: 502, reason: "Bad Gateway", mime: "text/plain",
                             body: Data("upstream: \(error.localizedDescription)".utf8))
            }
        }
    }

    /// 没有路由时的直连（用 URLSession 就够）
    private func fetchDirect(conn: NWConnection, target: URL, method: String, body: Data,
                             contentType: String?, allowFallback: Bool) {
        var req = URLRequest(url: target)
        req.httpMethod = method
        req.setValue(Self.browserUA, forHTTPHeaderField: "User-Agent")
        if method != "GET" && method != "HEAD" {
            req.httpBody = body
            if let ct = contentType { req.setValue(ct, forHTTPHeaderField: "Content-Type") }
        }
        session.dataTask(with: req) { [weak self] data, resp, err in
            guard let self = self else { return }
            if let e = err {
                if allowFallback, let h = target.host, let fb = self.router.fallbackRoute(for: h) {
                    PXVRLogger.info("[proxy] 直连失败，回退 \(fb.address)")
                    self.fetch(conn: conn, target: target, method: method, body: body,
                               clientHeaders: [:], route: fb, allowFallback: false)
                    return
                }
                PXVRLogger.warning("[proxy] 抓取失败: \(e.localizedDescription)")
                self.respond(conn, status: 502, reason: "Bad Gateway", mime: "text/plain",
                             body: Data("upstream: \(e.localizedDescription)".utf8))
                return
            }
            let http = resp as? HTTPURLResponse
            let mime = http?.mimeType ?? "application/octet-stream"
            var payload = data ?? Data()
            if mime.contains("html") || mime.contains("css") {
                if let text = String(data: payload, encoding: .utf8) {
                    payload = Data(Self.rewrite(text, base: target).utf8)
                }
            }
            self.respond(conn, status: http?.statusCode ?? 200, reason: "OK", mime: mime, body: payload)
        }.resume()
    }

    // MARK: - 输出

    private func respond(_ conn: NWConnection, status: Int, reason: String, mime: String, body: Data) {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(mime)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - URL 编解码与改写

    static let browserUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// 把真实地址编码成代理路径：/p?u=https%3A%2F%2F...
    static func proxyPath(_ absolute: String) -> String? {
        guard !absolute.isEmpty else { return nil }
        // 只保留字母数字，其余全部百分号编码，避免任何二次解析
        let strict = CharacterSet.alphanumerics
        guard let enc = absolute.addingPercentEncoding(withAllowedCharacters: strict) else { return nil }
        return "/p?u=\(enc)"
    }

    /// "/p?u=https%3A%2F%2F..." → URL
    static func decodeTarget(_ rawPath: String) -> URL? {
        guard rawPath.hasPrefix("/p?"),
              let comps = URLComponents(string: "http://localhost" + rawPath),
              let value = comps.queryItems?.first(where: { $0.name == "u" })?.value,
              !value.isEmpty
        else { return nil }
        return URL(string: value)
    }

    /// 把页面里的链接改写成本地代理路径
    static func rewrite(_ html: String, base: URL) -> String {
        var out = html

        // 1) 绝对地址：https://x/y → /p?u=...
        if let re = try? NSRegularExpression(pattern: "https?://[^\\s\"'<>()]+") {
            out = replaceAll(out, re) { match in
                proxyPath(match) ?? match
            }
        }

        // 2) 根相对地址：href="/x" → href="/p?u=<origin>/x"
        if let scheme = base.scheme, let host = base.host,
           let re2 = try? NSRegularExpression(pattern: "(?:href|src|action)=\"(/[^\"]*)\"") {
            let origin = "\(scheme)://\(host)"
            out = replaceAll(out, re2) { match in
                guard let eq = match.range(of: "=\"") else { return match }
                let attr = String(match[..<eq.lowerBound])          // href / src / action
                var value = String(match[eq.upperBound...])         // /x"
                if value.hasSuffix("\"") { value.removeLast() }
                if value.hasPrefix("/p?u=") { return match }        // 已经是代理路径
                let encoded = proxyPath(origin + value) ?? value
                return "\(attr)=\"\(encoded)\""
            }
        }
        return out
    }

    /// 用正则逐段替换
    private static func replaceAll(_ input: String, _ re: NSRegularExpression,
                                   _ transform: (String) -> String) -> String {
        let ns = input as NSString
        let matches = re.matches(in: input, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return input }
        var result = input
        for m in matches.reversed() {
            guard let r = Range(m.range, in: result) else { continue }
            result.replaceSubrange(r, with: transform(String(result[r])))
        }
        return result
    }
}

// MARK: - 证书

private final class PermissiveDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    /// 重定向时：打印目标 + 保住 Host / X-pxb 头，且 URL 仍指向节点。
    /// URLSession 转发重定向会丢掉自定义头，导致节点看不懂、反复 302。
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        PXVRLogger.info("[proxy] 重定向 \(response.statusCode) → \(request.url?.absoluteString.prefix(100) ?? "-")")
        var new = request
        if let orig = task.originalRequest {
            if let h = orig.value(forHTTPHeaderField: "Host") {
                new.setValue(h, forHTTPHeaderField: "Host")
            }
            for (k, v) in (orig.allHTTPHeaderFields ?? [:]) where k.lowercased().hasPrefix("x-px") {
                new.setValue(v, forHTTPHeaderField: k)
            }
            if let o = orig.url,
               let ou = URLComponents(url: o, resolvingAgainstBaseURL: false),
               var nu = URLComponents(url: new.url ?? o, resolvingAgainstBaseURL: false) {
                nu.scheme = ou.scheme
                nu.host = ou.host
                nu.port = ou.port
                if let fixed = nu.url { new.url = fixed }
            }
        }
        completionHandler(new)
    }
}
