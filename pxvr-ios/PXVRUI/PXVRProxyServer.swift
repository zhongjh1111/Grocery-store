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
    func entryURL(for target: String) -> URL? {
        guard port > 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/\(target)")
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

        var req = URLRequest(url: target)
        req.httpMethod = method
        req.httpShouldHandleCookies = true
        // 伪装成浏览器，页面才给正常内容
        req.setValue(Self.browserUA, forHTTPHeaderField: "User-Agent")
        req.setValue(target.absoluteString, forHTTPHeaderField: "Referer")
        if method != "GET" && method != "HEAD" {
            req.httpBody = body
            if let ct = headers["Content-Type"] { req.setValue(ct, forHTTPHeaderField: "Content-Type") }
        }

        session.dataTask(with: req) { [weak self] data, resp, err in
            guard let self = self else { return }
            if let e = err {
                PXVRLogger.warning("[proxy] 抓取失败: \(e.localizedDescription)")
                self.respond(conn, status: 502, reason: "Bad Gateway", mime: "text/plain",
                             body: Data("upstream: \(e.localizedDescription)".utf8))
                return
            }
            let http = resp as? HTTPURLResponse
            let mime = http?.mimeType ?? "application/octet-stream"
            var payload = data ?? Data()

            // HTML / CSS 里的链接改写成本地代理形式
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

    /// "/https://a/b" → URL
    static func decodeTarget(_ rawPath: String) -> URL? {
        let decoded = rawPath.removingPercentEncoding ?? rawPath
        var p = decoded
        if p.hasPrefix("/") { p.removeFirst() }
        guard !p.isEmpty else { return nil }
        guard p.hasPrefix("http://") || p.hasPrefix("https://") else { return nil }
        return URL(string: p)
    }

    /// 把页面里的链接改写成本地代理路径
    static func rewrite(_ html: String, base: URL) -> String {
        var out = html

        // 1. 绝对链接：https://x/y → /https://x/y
        out = out.replacingOccurrences(of: "=\"https://", with: "=\"/https://")
        out = out.replacingOccurrences(of: "=\"http://", with: "=\"/http://")
        out = out.replacingOccurrences(of: "(\"https://", with: "(\"/https://")
        out = out.replacingOccurrences(of: "('https://", with: "('/https://")
        out = out.replacingOccurrences(of: "url(https://", with: "url(/https://")
        out = out.replacingOccurrences(of: "url('https://", with: "url('/https://")
        out = out.replacingOccurrences(of: "url(\"https://", with: "url(\"/https://")

        // 2. 根相对链接：="/xxx" → base 的 host 拼回去
        //    只在 HTML 属性上做，避免误伤 JS 里的字符串
        if let scheme = base.scheme, let host = base.host {
            let prefix = "\(scheme)://\(host)"
            out = out.replacingOccurrences(of: "=\"/", with: "=\"/\(prefix)/")
            out = out.replacingOccurrences(of: "url(/", with: "url(\(prefix)/")
        }
        return out
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
}
