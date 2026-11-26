//
//  PXVRMITMServer.swift
//  PXVRUI
//
//  真·本地 MITM 代理 —— 对应原版 ProxyController + 自签证书那一套。
//
//  · 监听 127.0.0.1:<port>，处理 CONNECT 与普通 HTTP
//  · CONNECT 回 200 后用预置 p12 做服务端 TLS（SecureTransport）
//  · 解密后的请求按 Host 查路由表，明文转发到节点（与原版一致）
//  · 非白名单域名走原始隧道透传（系统代理会把所有 App 流量吸过来）
//
//  与 URL 改写方案的根本区别：页面里的 URL 永远保持原样。
//

import Foundation
import Security
import Darwin

// MARK: - 预置证书

final class PXVRIdentity {
    static let shared = PXVRIdentity()
    private(set) var identity: SecIdentity?

    private init() {
        guard let url = Bundle.main.url(forResource: "leaf", withExtension: "p12"),
              let data = try? Data(contentsOf: url) else {
            PXVRLogger.warning("[mitm] 找不到 leaf.p12")
            return
        }
        var items: CFArray?
        let opts = [kSecImportExportPassphrase as String: "pxvr"] as CFDictionary
        guard SecPKCS12Import(data as CFData, opts, &items) == errSecSuccess,
              let arr = items as? [[String: Any]],
              let first = arr.first,
              let idRef = first[kSecImportItemIdentity as String] else {
            PXVRLogger.warning("[mitm] p12 导入失败")
            return
        }
        identity = (idRef as! SecIdentity)
        PXVRLogger.info("[mitm] 证书已加载")
    }
}

// MARK: - SSL 回调（C 函数指针）

private func sslReadCallback(_ ref: SSLConnectionRef,
                             _ data: UnsafeMutableRawPointer,
                             _ len: UnsafeMutablePointer<Int>) -> OSStatus {
    let fd = Int32(truncatingIfNeeded: Int(bitPattern: ref))
    let want = len.pointee
    let n = read(fd, data, want)
    if n > 0 { len.pointee = n; return errSecSuccess }
    len.pointee = 0
    if n == 0 { return errSSLClosedGraceful }
    return errSSLWouldBlock
}

private func sslWriteCallback(_ ref: SSLConnectionRef,
                              _ data: UnsafeRawPointer,
                              _ len: UnsafeMutablePointer<Int>) -> OSStatus {
    let fd = Int32(truncatingIfNeeded: Int(bitPattern: ref))
    let want = len.pointee
    let n = write(fd, data, want)
    if n > 0 { len.pointee = n; return errSecSuccess }
    len.pointee = 0
    return errSSLWouldBlock
}

// MARK: - 代理主体

final class PXVRMITMServer {

    static let shared = PXVRMITMServer()

    private var listenFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "pxvr.mitm.accept")
    private let workQueue = DispatchQueue(label: "pxvr.mitm.work", attributes: .concurrent)
    private(set) var port: UInt16 = 0
    private(set) var running = false

    /// 需要中间人的域名后缀，其余一律隧道透传
    private let mitmSuffixes = [
        "pixiv.net", "pximg.net", "pixiv.org", "fanbox.cc",
        "pixivision.net", "pixivsketch.net", "b00k.pw", "pxvr.xyz", "ngee.net",
    ]

    private init() {}

    @discardableResult
    func start(port requested: UInt16 = 8899) -> Bool {
        guard !running else { return true }
        listenFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else { return false }

        var yes: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = requested.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0, listen(listenFD, 128) == 0 else {
            PXVRLogger.warning("[mitm] 端口 \(requested) 绑定失败")
            close(listenFD); listenFD = -1
            return false
        }

        port = requested
        running = true
        PXVRLogger.info("[mitm] 代理启动 127.0.0.1:\(requested)")
        acceptQueue.async { [weak self] in self?.acceptLoop() }
        return true
    }

    func stop() {
        running = false
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        PXVRLogger.info("[mitm] 代理停止")
    }

    private func acceptLoop() {
        while running {
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let fd = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listenFD, $0, &len)
                }
            }
            guard fd >= 0 else {
                if running { usleep(20_000); continue }
                break
            }
            var one: Int32 = 1
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            workQueue.async { [weak self] in
                guard let self = self else { close(fd); return }
                self.handle(fd: fd)
                close(fd)
            }
        }
    }

    private func needsMITM(_ host: String) -> Bool {
        let h = host.lowercased()
        return mitmSuffixes.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    // MARK: - 单连接

    private func handle(fd: Int32) {
        guard let head = readHead(fd: fd) else { return }
        let first = head.components(separatedBy: "\r\n").first ?? ""

        if first.uppercased().hasPrefix("CONNECT ") {
            let parts = first.split(separator: " ")
            guard parts.count >= 2 else { return }
            let hostPort = String(parts[1])
            let hp = hostPort.split(separator: ":")
            let host = String(hp.first ?? "")
            let port = hp.count > 1 ? (UInt16(hp[1]) ?? 443) : 443

            _ = writeAll(fd: fd, Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8))

            if needsMITM(host) {
                PXVRLogger.info("[mitm] 中间人 \(host):\(port)")
                serveTLS(fd: fd, host: host, port: port)
            } else {
                tunnel(fd: fd, host: host, port: port, alreadyRead: Data())
            }
            return
        }

        // 明文 HTTP
        forwardPlain(fd: fd, rawHead: head + "\r\n\r\n")
    }

    // MARK: - TLS 服务端

    private func serveTLS(fd: Int32, host: String, port: UInt16) {
        guard let identity = PXVRIdentity.shared.identity else { return }
        guard let ctx = SSLCreateContext(nil, .serverSide, .streamType) else { return }
        defer { SSLClose(ctx) }   // ARC 会释放 SSLContext

        let connRef = UnsafeMutableRawPointer(bitPattern: Int(fd)) ?? UnsafeMutableRawPointer(bitPattern: 1)!
        SSLSetConnection(ctx, UnsafeRawPointer(connRef))
        SSLSetIOFuncs(ctx, sslReadCallback, sslWriteCallback)
        SSLSetCertificate(ctx, [identity] as CFArray)
        SSLSetProtocolVersionMin(ctx, .tlsProtocol12)

        var status = SSLHandshake(ctx)
        var spins = 0
        while status == errSSLWouldBlock && spins < 2000 {
            usleep(2000)
            status = SSLHandshake(ctx)
            spins += 1
        }
        guard status == errSecSuccess else {
            PXVRLogger.warning("[mitm] TLS 握手失败 \(status)")
            return
        }

        // 循环处理这条 TLS 连接上的请求
        while true {
            guard let head = sslReadHead(ctx: ctx) else { break }
            if head.isEmpty { break }

            let lines = head.components(separatedBy: "\r\n")
            let reqLine = lines.first ?? ""
            let segs = reqLine.split(separator: " ")
            guard segs.count >= 2 else { break }
            let method = String(segs[0])
            let path = String(segs[1])

            var body = Data()
            if let cl = header(head, "Content-Length"), let n = Int(cl), n > 0 {
                body = sslRead(ctx: ctx, count: n) ?? Data()
            }

            let req = rebuildRequest(head: head, method: method, path: path, host: host)
            guard let resp = PXVRUpstream.shared.send(host: host, port: port,
                                                      request: req, body: body) else {
                _ = sslWrite(ctx: ctx, Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n".utf8))
                break
            }

            if !sslWrite(ctx: ctx, resp) { break }

            // 响应里带 Connection: close 就收工
            if resp.range(of: Data("Connection: close".utf8)) != nil { break }
        }
    }

    private func rebuildRequest(head: String, method: String, path: String, host: String) -> String {
        var out = "\(method) \(path) HTTP/1.1\r\n"
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            let low = line.lowercased()
            if low.hasPrefix("connection:") || low.hasPrefix("proxy-connection:") { continue }
            if !line.isEmpty { out += line + "\r\n" }
        }
        out += "Connection: close\r\n\r\n"
        return out
    }

    // MARK: - 透传隧道

    private func tunnel(fd: Int32, host: String, port: UInt16, alreadyRead: Data) {
        guard let up = PXVRUpstream.shared.openRaw(host: host, port: port) else { return }
        defer { close(up) }
        if !alreadyRead.isEmpty { _ = writeAll(fd: up, alreadyRead) }

        let group = DispatchGroup()
        workQueue.async(group: group) { self.pump(from: fd, to: up) }
        workQueue.async(group: group) { self.pump(from: up, to: fd) }
        _ = group.wait(timeout: .now() + 60)
    }

    private func pump(from: Int32, to: Int32) {
        var buf = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = read(from, &buf, buf.count)
            if n <= 0 { break }
            if !writeAll(fd: to, Data(buf[0..<n])) { break }
        }
        shutdown(to, SHUT_WR)
    }

    // MARK: - 明文 HTTP

    private func forwardPlain(fd: Int32, rawHead: String) {
        let host = header(rawHead, "Host")?
            .split(separator: ":").first.map(String.init) ?? ""
        guard !host.isEmpty else { return }
        let hostField = header(rawHead, "Host") ?? ""
        let portStr = hostField.split(separator: ":").count > 1
            ? String(hostField.split(separator: ":").last!) : "80"
        let port = UInt16(portStr) ?? 80
        guard let resp = PXVRUpstream.shared.send(host: host, port: port, request: rawHead, body: Data()) else { return }
        _ = writeAll(fd: fd, resp)
    }

    // MARK: - IO 工具

    private func header(_ head: String, _ name: String) -> String? {
        for line in head.components(separatedBy: "\r\n") {
            if let r = line.range(of: ":") {
                let k = line[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                if k.lowercased() == name.lowercased() {
                    return line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }

    private func readHead(fd: Int32) -> String? {
        var buf = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        while buf.count < 64 * 1024 {
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { return nil }
            buf.append(contentsOf: tmp[0..<n])
            if let s = String(data: buf, encoding: .utf8), s.contains("\r\n\r\n") {
                return s.components(separatedBy: "\r\n\r\n").first
            }
        }
        return nil
    }

    private func sslReadHead(ctx: SSLContext) -> String? {
        var buf = Data()
        while buf.count < 64 * 1024 {
            guard let chunk = sslRead(ctx: ctx, count: 4096, partial: true) else { return nil }
            if chunk.isEmpty { return nil }
            buf.append(chunk)
            if let s = String(data: buf, encoding: .utf8), s.contains("\r\n\r\n") {
                return s.components(separatedBy: "\r\n\r\n").first
            }
        }
        return nil
    }

    private func sslRead(ctx: SSLContext, count: Int, partial: Bool = false) -> Data? {
        var out = Data()
        let chunkSize = min(count, 16384)
        var buf = [UInt8](repeating: 0, count: chunkSize)
        while out.count < count {
            var got = 0
            let st = buf.withUnsafeMutableBytes { raw -> OSStatus in
                SSLRead(ctx, raw.baseAddress!, chunkSize, &got)
            }
            if got > 0 { out.append(contentsOf: buf[0..<got]) }
            if st == errSSLWouldBlock {
                if partial && !out.isEmpty { return out }
                usleep(2000)
                continue
            }
            if st != errSecSuccess { return out.isEmpty ? nil : out }
            if partial && !out.isEmpty { return out }
            if out.count >= count { break }
        }
        return out
    }

    private func sslWrite(ctx: SSLContext, _ data: Data) -> Bool {
        var sent = 0
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            while sent < data.count {
                var wrote = 0
                let st = SSLWrite(ctx, base + sent, data.count - sent, &wrote)
                sent += wrote
                if st == errSSLWouldBlock { usleep(2000); continue }
                if st != errSecSuccess { return false }
            }
            return true
        }
    }

    private func writeAll(fd: Int32, _ data: Data) -> Bool {
        var sent = 0
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            while sent < data.count {
                let n = write(fd, base + sent, data.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }
}

// MARK: - 上游转发

final class PXVRUpstream {
    static let shared = PXVRUpstream()
    private init() {}

    func openRaw(host: String, port: UInt16) -> Int32? {
        guard let ip = Self.resolve(host) else { return nil }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(ip)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0 else { close(fd); return nil }
        return fd
    }

    /// 按路由表把请求明文发到节点，读到断开为止
    func send(host: String, port: UInt16, request: String, body: Data) -> Data? {
        let chain = PXVRProxyServer.shared.router.chain(for: host)
        for route in chain {
            guard let fd = openRaw(host: route.host, port: UInt16(route.port)) else { continue }
            defer { close(fd) }

            var req = request
            if let n = route.headerName, let v = route.headerValue {
                req = req.replacingOccurrences(of: "\r\n\r\n",
                                               with: "\r\n\(n): \(v)\r\n\r\n")
            }
            guard writeAll(fd: fd, Data(req.utf8)) else { continue }
            if !body.isEmpty { _ = writeAll(fd: fd, body) }

            var resp = Data()
            var buf = [UInt8](repeating: 0, count: 16384)
            while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                resp.append(contentsOf: buf[0..<n])
            }
            if !resp.isEmpty { return resp }
        }
        return nil
    }

    private func writeAll(fd: Int32, _ data: Data) -> Bool {
        var sent = 0
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            while sent < data.count {
                let n = write(fd, base + sent, data.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    private static func resolve(_ host: String) -> String? {
        if inet_addr(host) != INADDR_NONE { return host }
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(res) }
        var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var sa = first.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        inet_ntop(AF_INET, &sa.sin_addr, &ip, socklen_t(INET_ADDRSTRLEN))
        return String(cString: ip)
    }
}
