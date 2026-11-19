//
//  PXVRRawHTTP.swift
//  PXVRUI
//
//  手写 HTTP/1.1 客户端（NWConnection + TLS）。
//
//  为什么不用 URLSession：
//    节点支持 ALPN h2，URLSession 会协商成 HTTP/2。
//    h2 的请求用 `:authority` 表达主机，自定义 `Host` 头不参与路由，
//    节点认不出目标站 → 一直 302 → URLSession 报 "too many HTTP redirects"。
//
//  这里强制 ALPN 只谈 http/1.1，并手写 Host 头，行为和原版 OkHttp 一致。
//  实测：同样的请求头走 HTTP/1.1 返回 200 + 真实 pixiv 页面。
//

import Foundation
import Network
import Security

enum PXVRRawHTTP {

    struct Response {
        let status: Int
        let headers: [String: String]   // 键统一小写
        let body: Data
    }

    /// 发一个请求，读到连接关闭为止（固定带 Connection: close）
    static func request(host: String,
                        port: UInt16,
                        method: String,
                        path: String,
                        headers: [String: String],
                        body: Data?) async throws -> Response {

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in
            complete(true)                     // 节点证书是自签的，全部接受
        }, DispatchQueue.global())

        // 关键：只宣告 http/1.1，避免被协商成 h2
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")

        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        params.allowLocalEndpointReuse = true

        let conn = NWConnection(host: NWEndpoint.Host(host),
                                port: NWEndpoint.Port(rawValue: port) ?? 443,
                                using: params)

        let queue = DispatchQueue(label: "pxvr.rawhttp")
        var raw = Data()

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var finished = false
            func finish(_ err: Error?) {
                if finished { return }
                finished = true
                if let e = err { cont.resume(throwing: e) } else { cont.resume() }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(nil)
                case .failed(let e): finish(e)
                case .cancelled: finish(NWError.posix(.ECANCELED))
                default: break
                }
            }
            conn.start(queue: queue)
        }

        // 拼请求
        var req = "\(method) \(path) HTTP/1.1\r\n"
        for (k, v) in headers { req += "\(k): \(v)\r\n" }
        if let b = body, !b.isEmpty {
            req += "Content-Length: \(b.count)\r\n"
        }
        req += "\r\n"
        var payload = Data(req.utf8)
        if let b = body, !b.isEmpty { payload.append(b) }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: payload, completion: .contentProcessed { err in
                if let e = err { cont.resume(throwing: e) } else { cont.resume() }
            })
        }

        // 一直读到 EOF（服务端会因为我们发了 Connection: close 而主动关闭）
        while true {
            let (chunk, isComplete) = try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<(Data?, Bool), Error>) in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isDone, err in
                    if let e = err { cont.resume(throwing: e) } else { cont.resume(returning: (data, isDone)) }
                }
            }
            if let c = chunk { raw.append(c) }
            if isComplete || chunk == nil { break }
        }
        conn.cancel()

        return try parse(raw)
    }

    // MARK: - 解析

    private static func parse(_ raw: Data) throws -> Response {
        guard let sep = raw.range(of: Data("\r\n\r\n".utf8)) else {
            throw NSError(domain: "PXVRRawHTTP", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "响应缺少头部结束标记"])
        }
        let headText = String(data: raw[..<sep.lowerBound], encoding: .utf8) ?? ""
        var bodyData = raw[sep.upperBound...]

        var lines = headText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw NSError(domain: "PXVRRawHTTP", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "缺少状态行"])
        }
        let parts = statusLine.split(separator: " ")
        let status = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0

        lines.removeFirst()
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[k] = v
        }

        // 分块编码
        if let te = headers["transfer-encoding"], te.lowercased().contains("chunked") {
            bodyData = decodeChunked(Data(bodyData))
        } else if let len = headers["content-length"], let n = Int(len) {
            if bodyData.count > n { bodyData = bodyData.prefix(n) }
        }

        return Response(status: status, headers: headers, body: Data(bodyData))
    }

    /// 解 Transfer-Encoding: chunked
    private static func decodeChunked(_ data: Data) -> Data {
        var out = Data()
        var idx = data.startIndex
        while idx < data.endIndex {
            // 读长度行
            guard let lineEnd = data[idx...].range(of: Data("\r\n".utf8)) else { break }
            let line = String(data: data[idx..<lineEnd.lowerBound], encoding: .utf8) ?? "0"
            let hex = line.split(separator: ";").first.map(String.init) ?? "0"
            guard let size = Int(hex.trimmingCharacters(in: .whitespaces), radix: 16) else { break }
            idx = lineEnd.upperBound
            if size == 0 { break }
            let end = data.index(idx, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            out.append(data[idx..<end])
            idx = end
            // 跳过块尾 CRLF
            if let crlf = data[idx...].range(of: Data("\r\n".utf8)) {
                idx = crlf.upperBound
            } else { break }
        }
        return out
    }
}
