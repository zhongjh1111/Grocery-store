//
//  PXVRRouter.swift
//  PXVRUI
//
//  路由表，严格按原版数据与逻辑实现。
//
//  三张表的语义（由 ph 与 ralt 的主机名一一对应关系确证）：
//
//  ph*   主路由。端点有四种：
//        "ip:port/头:值"      → 连该节点，加鉴权头
//        "210.140.139.151"    → 直连该 IP（Host 仍是原站，domain-fronting）
//        "#pxf" / "#ht"       → 引用 sg* 节点组
//        "#cf"                → 首选直连（无节点）
//
//  sg*   节点组：#ht / #pxf / #pxfi → 首个端点
//
//  ralt* 备路由。ph 里标 #cf 的主机，直连失败后改走这里（#pxf 节点）。
//        例：ph34 = www.pixiv.net none #cf
//            ralt0 = pixiv www.pixiv.net #pxf 1
//
//  实测（2026-11-16 22:09 雷电）：国内直连 pixiv 必失败 → 全部触发回退 → 只见节点连接。
//

import Foundation

final class PXVRRouter {

    struct Route {
        let address: String          // "58.246.149.105:50242" 或 "210.140.139.151:443"
        let headerName: String?      // "X-pxb"；裸 IP 直连时为 nil
        let headerValue: String?     // "token,ts,sig"

        var host: String {
            let parts = address.split(separator: ":")
            return parts.isEmpty ? address : String(parts[0])
        }
        var port: Int {
            let parts = address.split(separator: ":")
            guard parts.count > 1, let p = Int(parts[1]) else { return 443 }
            return p
        }
    }

    /// ph 表：精确主机 → 主路由（#cf 不写入 = 直连）
    private(set) var exact: [String: Route] = [:]
    /// ph 表：正则主机 → 主路由
    private(set) var patterns: [(NSRegularExpression, Route)] = []
    /// sg 表：组名 → 节点
    private(set) var groups: [String: Route] = [:]
    /// ralt 表：主机 → 备路由
    private(set) var fallback: [String: Route] = [:]

    /// 失败记录：地址 → 失败时间。失败的节点在冷却期内排到最后，
    /// 避免每个请求都先撞一次 302 再回退（实测会让页面明显发钝）。
    /// ji*：页面注入（正则 → 要插入的 script 标签）
    private(set) var injections: [(NSRegularExpression, String)] = []
    /// hnrw*：图片域名改写（旧 → 新）
    private(set) var hostRewrites: [(from: String, to: String)] = []
    /// bd*：屏蔽的域名（命中直接返回空）
    private(set) var blocked: [NSRegularExpression] = []

    /// 路由表会被多个连接并发读、配置刷新时并发写，必须加锁
    private let lock = NSRecursiveLock()
    private var failedAt: [String: Date] = [:]
    private let failCooldown: TimeInterval = 600

    func markFailed(_ address: String) {
        lock.lock(); defer { lock.unlock() }
        failedAt[address] = Date()
    }

    private func isCoolingDown(_ address: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let t = failedAt[address] else { return false }
        return Date().timeIntervalSince(t) < failCooldown
    }

    /// 用 /xc 下发的配置重建
    func load(_ config: [String: Any]) {
        exact.removeAll(); patterns.removeAll(); groups.removeAll(); fallback.removeAll()
        injections.removeAll(); hostRewrites.removeAll(); blocked.removeAll()

        // ① sg* 节点组
        if let n = intValue(config["sg"]) {
            for i in 0..<n {
                guard let line = config["sg\(i)"] as? String else { continue }
                let parts = line.split(separator: " ").map(String.init)
                guard parts.count >= 2, parts[0].hasPrefix("#") else { continue }
                if let r = Self.parseEndpoint(parts[1]) {
                    groups[parts[0]] = r
                }
            }
        }

        // ② ralt* 备路由：`<组> <主机> <模式> <标志>`
        if let n = intValue(config["ralt"]) {
            for i in 0..<n {
                guard let line = config["ralt\(i)"] as? String else { continue }
                let parts = line.split(separator: " ").map(String.init)
                guard parts.count >= 3 else { continue }
                let host = parts[1]
                let mode = parts[2]
                if let r = groups[mode] ?? Self.parseEndpoint(mode) {
                    fallback[host] = r
                }
            }
        }

        // ③ ji* 注入：`<正则> <script...>`（正则与脚本之间是第一个空格）
        if let n = intValue(config["ji"]) {
            for i in 0..<n {
                guard let line = config["ji\(i)"] as? String,
                      let sp = line.firstIndex(of: " ") else { continue }
                let pattern = String(line[..<sp])
                let scripts = String(line[line.index(after: sp)...])
                if let re = try? NSRegularExpression(pattern: pattern) {
                    injections.append((re, scripts))
                }
            }
        }

        // ④ hnrw* 域名改写：`新主机/旧主机`
        if let n = intValue(config["hnrw"]) {
            for i in 0..<n {
                guard let line = config["hnrw\(i)"] as? String else { continue }
                let parts = line.split(separator: "/").map(String.init)
                if parts.count >= 2 { hostRewrites.append((from: parts[1], to: parts[0])) }
            }
        }

        // ⑤ bd* 屏蔽域名
        if let n = intValue(config["bd"]) {
            for i in 0..<n {
                guard let line = config["bd\(i)"] as? String,
                      let re = try? NSRegularExpression(pattern: line) else { continue }
                blocked.append(re)
            }
        }

        // ⑥ ph* 主路由
        if let n = intValue(config["ph"]) {
            for i in 0..<n {
                guard let line = config["ph\(i)"] as? String else { continue }
                let parts = line.split(separator: " ").map(String.init)
                guard parts.count >= 3 else { continue }
                let host = parts[0]
                let mode = parts[1]
                guard let endpoint = parts[2...].first(where: { !$0.isEmpty }) else { continue }

                // "#cf" = 首选直连，不设主路由（失败时由 ralt 兜底）
                if endpoint == "#cf" { continue }

                let route: Route?
                if endpoint.hasPrefix("#") {
                    route = groups[endpoint]
                } else {
                    route = Self.parseEndpoint(endpoint)
                }
                guard let r = route else { continue }

                if host.hasPrefix("\\A") {
                    if let re = try? NSRegularExpression(pattern: host) {
                        patterns.append((re, r))
                    }
                } else if mode == "none" {
                    exact[host] = r
                }
            }
        }

        PXVRLogger.info("[proxy] 路由表：ph 精确 \(exact.count) / ph 正则 \(patterns.count) / 组 \(groups.count) / ralt \(fallback.count)")
    }

    /// 主路由；nil 表示直连
    func route(for host: String) -> Route? {
        lock.lock(); defer { lock.unlock() }
        if let r = exact[host] { return r }
        let range = NSRange(location: 0, length: (host as NSString).length)
        for (re, r) in patterns where re.firstMatch(in: host, range: range) != nil {
            return r
        }
        return nil
    }

    /// 备路由；nil 表示无备选
    func fallbackRoute(for host: String) -> Route? {
        fallback[host]
    }

    /// 回退链：主路由 → ralt → #ht 组。
    /// 实测 #pxf 下发的裸 token 会被节点拒绝（302 → errors-auth.html），
    /// 而 #ht 的 X-pxk 一直可用，所以把 #ht 作为最后兜底。
    func chain(for host: String) -> [Route] {
        lock.lock(); defer { lock.unlock() }
        var out: [Route] = []
        func add(_ r: Route?) {
            guard let r = r else { return }
            if !out.contains(where: { $0.address == r.address }) { out.append(r) }
        }
        add(route(for: host))
        add(fallback[host])
        add(groups["#ht"])
        // 冷却中的排到最后（仍保留作兜底）
        return out.sorted { !isCoolingDown($0.address) && isCoolingDown($1.address) }
    }

    /// 命中的注入脚本（没有则 nil）
    func injection(for url: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let range = NSRange(location: 0, length: (url as NSString).length)
        for (re, scripts) in injections where re.firstMatch(in: url, range: range) != nil {
            return scripts
        }
        return nil
    }

    /// 是否属于要屏蔽的域名
    func isBlocked(_ url: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let range = NSRange(location: 0, length: (url as NSString).length)
        for re in blocked where re.firstMatch(in: url, range: range) != nil { return true }
        return false
    }

    /// 把正文里的旧图片域名换成新域名（hnrw）
    func rewriteHosts(_ text: String) -> String {
        lock.lock(); defer { lock.unlock() }
        var out = text
        for (from, to) in hostRewrites where from != to {
            out = out.replacingOccurrences(of: "//\(from)/", with: "//\(to)/")
        }
        return out
    }

    // MARK: - 解析

    /// "58.246.149.105:50242/X-pxb:token" 或裸 "210.140.139.151" → Route
    /// 对应 ws0.u0()：按第一个 '/' 劈地址与鉴权；无 '/' 即裸 IP 直连
    static func parseEndpoint(_ s: String) -> Route? {
        guard !s.isEmpty else { return nil }
        guard let slash = s.firstIndex(of: "/") else {
            // 裸 IP（或 ip:port）：直连，无鉴权头
            let addr = s.contains(":") ? s : s + ":443"
            return Route(address: addr, headerName: nil, headerValue: nil)
        }
        let address = String(s[s.startIndex..<slash])
        let auth = String(s[s.index(after: slash)...])
        guard !address.isEmpty, !auth.isEmpty else { return nil }
        guard let colon = auth.firstIndex(of: ":") else { return nil }
        let name = String(auth[auth.startIndex..<colon])
        let value = String(auth[auth.index(after: colon)...])
        guard !name.isEmpty, !value.isEmpty else { return nil }
        return Route(address: address, headerName: name, headerValue: value)
    }

    private func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let s = any as? String { return Int(s) }
        return nil
    }
}
