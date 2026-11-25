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

        // 原版对 favicon 也直接返回空 200
        if target.path == "/favicon.ico" {
            respond(conn, status: 200, reason: "OK", mime: "image/x-icon", body: Data())
            return
        }

        // 原版 bd* 列表：广告/统计域名直接吞掉，不产生任何请求
        if router.isBlocked(target.absoluteString) {
            PXVRLogger.info("[proxy] 屏蔽 \(target.host ?? "")")
            respond(conn, status: 204, reason: "No Content", mime: "text/plain", body: Data())
            return
        }

        PXVRLogger.info("[proxy] \(method) \(target.absoluteString.prefix(120))")

        // 回退链：主路由 → ralt → #ht
        let chain = router.chain(for: target.host ?? "")
        PXVRLogger.info("[proxy] 路由链 \(chain.map(\.address).joined(separator: " → "))")
        fetch(conn: conn, target: target, method: method, body: body,
              clientHeaders: headers, routes: chain)
    }

    /// 对应原版 lj0.c()：连节点、Host 留原站、加鉴权头。
    /// 走手写 HTTP/1.1（PXVRRawHTTP）：URLSession 会协商成 h2，
    /// 而 h2 用 :authority 表达主机，Host 头不参与路由 → 节点 302 死循环。
    private func fetch(conn: NWConnection, target: URL, method: String, body: Data,
                       clientHeaders: [String: String], routes: [PXVRRouter.Route]) {
        guard let r = routes.first else {
            fetchDirect(conn: conn, target: target, method: method, body: body,
                        contentType: clientHeaders["Content-Type"], allowFallback: false)
            return
        }
        let rest = Array(routes.dropFirst())

        let host = target.host ?? r.host
        var path = target.path.isEmpty ? "/" : target.path
        if let q = URLComponents(url: target, resolvingAgainstBaseURL: false)?.percentEncodedQuery,
           !q.isEmpty {
            path += "?" + q
        }

        // 原样透传浏览器的头（X-CSRF-Token / Origin / X-Requested-With 等缺一不可，
        // 少一个 pixiv 的 ajax 就回 400/422），只剔除逐跳头后重写关键项。
        var hdrs: [String: String] = [:]
        let hopByHop: Set<String> = ["host", "connection", "content-length", "accept-encoding",
                                     "keep-alive", "proxy-connection", "transfer-encoding", "te", "trailer"]
        for (k, v) in clientHeaders where !hopByHop.contains(k.lowercased()) {
            hdrs[k] = v
        }
        hdrs["Host"] = host
        hdrs["Accept-Encoding"] = "identity"      // 不压缩，省得解 gzip
        hdrs["Connection"] = "close"
        if hdrs["User-Agent"] == nil { hdrs["User-Agent"] = Self.browserUA }

        // 页面跑在 127.0.0.1 上，Referer/Origin 会变成内网地址。
        // pixiv 图床校验来源，这里统一换成站点真实地址。
        if let ref = hdrs["Referer"], ref.contains("127.0.0.1") {
            hdrs["Referer"] = "https://www.pixiv.net/"
        }
        if let org = hdrs["Origin"], org.contains("127.0.0.1") {
            hdrs["Origin"] = "https://www.pixiv.net"
        }
        if hdrs["Referer"] == nil, host.contains("pximg.net") {
            hdrs["Referer"] = "https://www.pixiv.net/"
        }

        if let n = r.headerName, let v = r.headerValue { hdrs[n] = v }

        PXVRLogger.info("[proxy] 路由 \(host) → \(r.address)  (\(r.headerName ?? "直连IP"))")

        let startedAt = Date()
        Task {
            do {
                let resp = try await PXVRRawHTTP.request(
                    host: r.host, port: UInt16(r.port), method: method, path: path,
                    headers: hdrs,
                    body: (method == "GET" || method == "HEAD") ? nil : body)

                let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
                PXVRLogger.info("[proxy] ← \(resp.status)  \(resp.body.count) 字节  \(host)\(path.prefix(30))  \(ms)ms")

                // 回填节点统计，供下一次 /xc 的 f / sr 上报
                if resp.status < 400 {
                    PXVRNodeStats.shared.recordSuccess(address: r.address, latencyMs: ms, bytes: resp.body.count)
                } else {
                    PXVRNodeStats.shared.recordFailure(address: r.address, latencyMs: ms)
                }

                // 302/4xx/5xx 说明这个节点不通（鉴权失败也是 302），换下一个
                if resp.status >= 300 {
                    // 节点鉴权失败的长这样：302 → https://h.b00k.pw/errors-auth.html
                    let loc = resp.headers["location"] ?? ""
                    let isNodeAuthFail = loc.contains("errors-auth") || loc.contains("b00k.pw")

                    // 真正的跳转（如 /login.php → /login）原样交给 WebView，
                    // 但改写成代理路径，避免跳出代理
                    if resp.status < 400, !loc.isEmpty, !isNodeAuthFail {
                        let abs = URL(string: loc, relativeTo: target)?.absoluteString ?? loc
                        let fixed = Self.proxyPath(abs) ?? loc
                        PXVRLogger.info("[proxy] 跳转 \(resp.status) → \(abs.prefix(70))")
                        self.respond(conn, status: resp.status, reason: "Redirect",
                                     mime: "text/html", body: resp.body,
                                     headers: ["Location": fixed])
                        return
                    }

                    self.router.markFailed(r.address)
                    if !rest.isEmpty {
                        PXVRLogger.info("[proxy] \(r.address) 返回 \(resp.status)，换下一个 → \(rest[0].address)")
                        self.fetch(conn: conn, target: target, method: method, body: body,
                                   clientHeaders: clientHeaders, routes: rest)
                        return
                    }
                    PXVRLogger.warning("[proxy] 所有节点都失败，最后一个状态 \(resp.status)")
                    self.respond(conn, status: 502, reason: "Bad Gateway", mime: "text/plain",
                                 body: Data("upstream: all routes failed (\(resp.status))".utf8))
                    return
                }

                let mime = resp.headers["content-type"] ?? "application/octet-stream"
                var payload = resp.body
                if mime.contains("html") || mime.contains("css") {
                    if var text = String(data: payload, encoding: .utf8) {
                        // ① 图片域名改写（i.pximg.net → i-cf.pximg.net 等）
                        text = self.router.rewriteHosts(text)
                        // ② 代理补丁：真实基址 + fetch/XHR 拦截（必须在页面脚本之前）
                        if mime.contains("html") {
                            let base = "\(target.scheme ?? "https")://\(target.host ?? "")"
                            let head = "<script>window.__PXVR_BASE__=\"\(base)\";</script><script>\(Self.proxyShimJS)</script>"
                            if let r = text.range(of: "<head>", options: .caseInsensitive) {
                                text.insert(contentsOf: head, at: r.upperBound)
                            } else {
                                text = head + text
                            }
                        }
                        // ③ 页面注入（jquery / tuf / 主题脚本）
                        if mime.contains("html"),
                           let scripts = self.router.injection(for: target.absoluteString) {
                            if let r = text.range(of: "</body>", options: .backwards) {
                                text.insert(contentsOf: scripts, at: r.lowerBound)
                            } else {
                                text += scripts
                            }
                            PXVRLogger.info("[proxy] 已注入脚本 \(target.host ?? "")")
                        }
                        // ③ 链接改写成本地代理路径
                        payload = Data(Self.rewrite(text, base: target).utf8)
                    }
                }
                self.respond(conn, status: resp.status,
                             reason: resp.status == 200 ? "OK" : "Status",
                             mime: mime, body: payload,
                             headers: Self.forwardableHeaders(resp.headers))
            } catch {
                self.router.markFailed(r.address)
                if !rest.isEmpty {
                    PXVRLogger.info("[proxy] \(r.address) 失败，换下一个 → \(rest[0].address)")
                    self.fetch(conn: conn, target: target, method: method, body: body,
                               clientHeaders: clientHeaders, routes: rest)
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
                               clientHeaders: [:], routes: [fb])
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

    private func respond(_ conn: NWConnection, status: Int, reason: String, mime: String,
                         body: Data, headers extra: [String: String] = [:]) {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(mime)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        for (k, v) in extra { head += "\(k): \(v)\r\n" }
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }


    /// 注入到每个 HTML 页面头部：
    /// 1) 告诉脚本真实基址（页面在 127.0.0.1 上，相对路径会解析错）
    /// 2) 拦截 fetch / XHR / 动态插入的 img|a|link，全部转成本地代理路径
    /// 原版靠 shouldInterceptRequest 天然做到，iOS 只能这样补。
    static let proxyShimJS = #"""
    (function(){
      if (window.__PXVR_SHIM__) return; window.__PXVR_SHIM__ = 1;
      var BASE = window.__PXVR_BASE__ || location.origin;
      function map(u){
        try{
          if(!u) return u;
          var s = String(u);
          if(s.indexOf('data:')===0||s.indexOf('blob:')===0||s.indexOf('javascript:')===0) return u;
          if(s.indexOf('/p?u=')===0) return u;
          if(s.charAt(0) === '#') return u;
          var abs = new URL(s, BASE).href;
          if(!/^https?:/.test(abs)) return u;
          return '/p?u=' + encodeURIComponent(abs);
        }catch(e){ return u; }
      }
      var of = window.fetch;
      if(of){ window.fetch = function(input, init){
        try{
          if(typeof input === 'string'){ input = map(input); }
          else if(input && input.url){ input = new Request(map(input.url), input); }
        }catch(e){}
        return of.call(this, input, init);
      };}
      try{
        if (navigator.serviceWorker) {
          navigator.serviceWorker.getRegistrations && navigator.serviceWorker.getRegistrations()
            .then(function(rs){ rs.forEach(function(r){ r.unregister(); }); }).catch(function(){});
          navigator.serviceWorker.register = function(){
            return Promise.reject(new Error('sw disabled under proxy'));
          };
        }
      }catch(e){}
      var oo = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(m,u){
        try{ arguments[1] = map(u); }catch(e){}
        return oo.apply(this, arguments);
      };
      function fixNode(n){
        try{
          if(!n || n.nodeType !== 1) return;
          ['src','href','poster','action'].forEach(function(attr){
            var v = n.getAttribute && n.getAttribute(attr);
            if(v && v.indexOf('/p?u=') !== 0){
              var mv = map(v);
              if(mv !== v){ n.setAttribute(attr, mv); }
            }
          });
          var ss = n.getAttribute && n.getAttribute('srcset');
          if(ss && ss.indexOf('http') >= 0){
            n.setAttribute('srcset', ss.split(',').map(function(p){
              var t = p.trim().split(/\s+/);
              return map(t[0]) + (t[1] ? ' ' + t[1] : '');
            }).join(', '));
          }
          if(n.querySelectorAll){ n.querySelectorAll('img,script,link,source').forEach(fixNode); }
        }catch(e){}
      }
      function sweep(){
        try{ document.querySelectorAll('img,script,link,source,a').forEach(fixNode); }catch(e){}
      }
      document.addEventListener('DOMContentLoaded', sweep);
      window.addEventListener('load', sweep);
      var n = 0;
      var timer = setInterval(function(){ sweep(); if(++n > 12) clearInterval(timer); }, 800);
      try{
        new MutationObserver(function(ms){
          ms.forEach(function(m){
            if(m.type === 'attributes'){ fixNode(m.target); }
            else { m.addedNodes.forEach(fixNode); }
          });
        }).observe(document.documentElement || document, {
          childList:true, subtree:true, attributes:true,
          attributeFilter:['src','href','srcset','poster']
        });
      }catch(e){}
    })();
    """#

    /// 只透传对浏览器有意义的头；Set-Cookie 需要改写
    private static func forwardableHeaders(_ src: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for key in ["cache-control", "expires", "etag", "last-modified", "content-disposition"] {
            if let v = src[key] { out[key.capitalized] = v }
        }
        if let sc = src["set-cookie"] {
            out["Set-Cookie"] = normalizeCookie(sc)
            PXVRLogger.info("[proxy] 下发 cookie \(sc.prefix(40))")
        }
        if let loc = src["location"] { out["Location"] = loc }
        return out
    }

    /// 代理是 http://127.0.0.1，原站的 Domain=.pixiv.net 会被浏览器拒收。
    /// 去掉 Domain / Secure / SameSite，让它变成 host-only 落到 127.0.0.1。
    private static func normalizeCookie(_ raw: String) -> String {
        var parts = raw.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        parts.removeAll { p in
            let l = p.lowercased()
            return l.hasPrefix("domain=") || l == "secure" || l.hasPrefix("samesite=")
        }
        return parts.joined(separator: "; ")
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
    /// 只改写「属性里的 URL」和「CSS 里的 url()」，**不动脚本内容**。
    /// 原版从不改页面内容（靠 WebView 拦截请求），我们只能改链接；
    /// 一旦把 <script> 里的字符串也换掉，JS 解析 URL 的逻辑就会坏。
    static func rewrite(_ html: String, base: URL) -> String {
        var out = html

        // 1) 属性：src / href / action / poster / data-src
        if let re = try? NSRegularExpression(
            pattern: "(src|href|action|poster|data-src)\\s*=\\s*([\"'])([^\"']*)\\2",
            options: [.caseInsensitive]) {
            out = replaceAll(out, re) { match in
                // match 形如  src="/x"  —— 拆出属性名和值
                guard let eq = match.range(of: "=") else { return match }
                let name = String(match[..<eq.lowerBound])
                var rest = String(match[eq.upperBound...])
                guard let q = rest.first, q == "\"" || q == "'" else { return match }
                rest.removeFirst()
                if rest.hasSuffix(String(q)) { rest.removeLast() }
                let value = rest
                guard let mapped = mapURL(value, base: base), mapped != value else { return match }
                return "\(name)=\(q)\(mapped)\(q)"
            }
        }

        // 2) srcset：逗号分隔的多地址
        if let re = try? NSRegularExpression(
            pattern: "srcset\\s*=\\s*([\"'])([^\"']*)\\1", options: [.caseInsensitive]) {
            out = replaceAll(out, re) { match in
                guard let q1 = match.firstIndex(of: "=") else { return match }
                let head = String(match[...q1])
                var rest = String(match[match.index(after: q1)...])
                guard let q = rest.first else { return match }
                rest.removeFirst()
                if rest.hasSuffix(String(q)) { rest.removeLast() }
                let items = rest.split(separator: ",").map { piece -> String in
                    let t = piece.trimmingCharacters(in: .whitespaces)
                    var comps = t.split(separator: " ").map(String.init)
                    if let first = comps.first, let m = mapURL(first, base: base) {
                        comps[0] = m
                    }
                    return comps.joined(separator: " ")
                }
                return "\(head)\(q)\(items.joined(separator: ", "))\(q)"
            }
        }

        // 3) CSS 里的 url(...)：<style> 与内联 style 都覆盖
        if let re = try? NSRegularExpression(pattern: "url\\(\\s*([\"']?)([^)\"']+)\\1\\s*\\)",
                                             options: [.caseInsensitive]) {
            out = replaceAll(out, re) { match in
                guard let l = match.firstIndex(of: "(") else { return match }
                var v = String(match[match.index(after: l)...])
                if v.hasSuffix(")") { v.removeLast() }
                let quoted = v.hasPrefix("\"") || v.hasPrefix("'")
                let q = quoted ? String(v.first!) : ""
                if quoted { v.removeFirst(); if v.hasSuffix(q) { v.removeLast() } }
                guard let mapped = mapURL(v, base: base), mapped != v else { return match }
                return "url(\(q)\(mapped)\(q))"
            }
        }

        return out
    }

    /// 单个 URL 转代理路径；不需要改的返回原值
    private static func mapURL(_ raw: String, base: URL) -> String? {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { return nil }
        let lower = v.lowercased()
        if lower.hasPrefix("data:") || lower.hasPrefix("blob:")
            || lower.hasPrefix("javascript:") || lower.hasPrefix("mailto:")
            || lower.hasPrefix("about:") || lower.hasPrefix("#")
            || lower.hasPrefix("/p?u=") { return nil }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return proxyPath(v)
        }
        if v.hasPrefix("/") {
            let origin = "\(base.scheme ?? "https")://\(base.host ?? "")"
            return proxyPath(origin + v)
        }
        // 相对路径：按当前页面地址解析
        if let abs = URL(string: v, relativeTo: base)?.absoluteString,
           abs.hasPrefix("http") {
            return proxyPath(abs)
        }
        return nil
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
