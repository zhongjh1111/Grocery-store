//
//  PXVRRouter.swift
//  PXVRUI
//
//  路由表。对应原版：
//    ws0 里的 ph 解析（ib.java case 4）
//    ws0.u0() 把端点劈成 "地址" 和 "头:值"
//    lj0.a() 把头发到请求上
//
//  配置格式（实测）：
//    ph0  = pv.b00k.pw none 58.246.149.105:50242/X-pxb:token,ts,sig
//    ph34 = www.pixiv.net none #cf
//    ph5  = accounts.pixiv.net none #cf
//    sg0  = #ht 106.14.242.60:50443/X-pxk:xxx|0/2/3/... 58.246.149.105:50242/...
//
//  解析后：
//    主机 → 路由(地址, 头名, 头值)
//    没有路由 / #cf → 直连
//

import Foundation

final class PXVRRouter {

    struct Route {
        let address: String        // "58.246.149.105:50242"
        let headerName: String     // "X-pxb"
        let headerValue: String    // "token,ts,sig"

        var host: String { String(address.split(separator: ":").first ?? "") }
        var port: Int { Int(address.split(separator: ":").last ?? "443") ?? 443 }
    }

    /// 精确主机映射
    private(set) var exact: [String: Route] = [:]
    /// 正则主机映射（配置里以 \A 开头的）
    private(set) var patterns: [(NSRegularExpression, Route)] = []
    /// 节点组：#ht / #pxf → 首个端点
    private(set) var groups: [String: Route] = [:]

    /// 用 /xc 下发的配置重建
    func load(_ config: [String: Any]) {
        exact.removeAll(); patterns.removeAll(); groups.removeAll()

        // ① 先解析节点组 sg*，供 #ht / #pxf 引用
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

        // ② 再解析主机表 ph*
        if let n = intValue(config["ph"]) {
            for i in 0..<n {
                guard let line = config["ph\(i)"] as? String else { continue }
                let parts = line.split(separator: " ").map(String.init)
                guard parts.count >= 3 else { continue }
                let host = parts[0]
                let mode = parts[1]
                // 端点可能不止一个，取第一个能用的
                guard let endpoint = parts[2...].first(where: { !$0.isEmpty }) else { continue }

                let route: Route?
                if endpoint.hasPrefix("#") {
                    // 引用节点组；#cf 表示直连
                    route = (endpoint == "#cf") ? nil : groups[endpoint]
                    if route == nil && endpoint != "#cf" { continue }
                    if endpoint == "#cf" { continue }
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
    }

    /// 查主机对应路由；nil 表示直连
    func route(for host: String) -> Route? {
        if let r = exact[host] { return r }
        let range = NSRange(location: 0, length: (host as NSString).length)
        for (re, r) in patterns where re.firstMatch(in: host, range: range) != nil {
            return r
        }
        return nil
    }

    // MARK: - 解析

    /// "58.246.149.105:50242/X-pxb:token" → Route
    /// 对应 ws0.u0()：按第一个 '/' 劈开
    static func parseEndpoint(_ s: String) -> Route? {
        guard let slash = s.firstIndex(of: "/") else { return nil }
        let address = String(s[s.startIndex..<slash])
        let auth = String(s[s.index(after: slash)...])
        guard !address.isEmpty, !auth.isEmpty else { return nil }
        // auth = "X-pxb:token,..." 按第一个 ':' 劈
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
