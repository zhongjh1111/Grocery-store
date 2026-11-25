//
//  PXVRNodeStats.swift
//  PXVRUI
//
//  节点质量统计 —— 对应原版 os0 的计数器与 ws0.b()/ws0.c() 的上报。
//
//  /xc 请求体里有两个字段专门回传这些数据：
//    f  = "host/m/j/l/i,..."            节点累计计数
//    sr = "ip|port|延迟|丢包%|评分;..."   节点质量样本
//  服务端据此为每台设备调度路线。不发这两个，就只能拿到默认节点。
//

import Foundation

final class PXVRNodeStats {

    static let shared = PXVRNodeStats()

    struct Stat {
        var attempts = 0
        var ok = 0
        var fail = 0
        var totalLatencyMs = 0
        var lastLatencyMs = 0
        var totalBytes = 0

        var avgLatency: Int { ok > 0 ? totalLatencyMs / ok : 0 }
        var lossPct: Int { attempts > 0 ? (fail * 100) / attempts : 0 }
        var score: Int { max(0, 100 - lossPct) }
    }

    private var map: [String: Stat] = [:]
    private let lock = NSLock()

    /// 累计流量（/xc 的 t 字段）
    private(set) var totalTraffic: Int {
        get { UserDefaults.standard.integer(forKey: "pxvr.traffic") }
        set { UserDefaults.standard.set(newValue, forKey: "pxvr.traffic") }
    }

    func recordSuccess(address: String, latencyMs: Int, bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        var s = map[address] ?? Stat()
        s.attempts += 1
        s.ok += 1
        s.totalLatencyMs += latencyMs
        s.lastLatencyMs = latencyMs
        s.totalBytes += bytes
        map[address] = s
        totalTraffic += bytes
    }

    func recordFailure(address: String, latencyMs: Int) {
        lock.lock(); defer { lock.unlock() }
        var s = map[address] ?? Stat()
        s.attempts += 1
        s.fail += 1
        s.lastLatencyMs = latencyMs
        map[address] = s
    }

    /// f 字段：host/m/j/l/i，按原版格式拼接
    func reportF() -> String? {
        lock.lock(); defer { lock.unlock() }
        let items = map.compactMap { addr, s -> String? in
            guard s.attempts > 0, !addr.isEmpty else { return nil }
            // m=成功数, j=连续失败(未知,填0), l=失败数, i=超时数(未知,填0)
            return "\(addr)/\(s.ok)/0/\(s.fail)/0"
        }
        return items.isEmpty ? nil : items.joined(separator: ",")
    }

    /// sr 字段：ip|port|延迟|丢包%|评分，分号分隔
    func reportSR() -> String? {
        lock.lock(); defer { lock.unlock() }
        let items = map.compactMap { addr, s -> String? in
            guard s.attempts > 0 else { return nil }
            let parts = addr.split(separator: ":")
            let host = String(parts.first ?? "")
            let port = parts.count > 1 ? String(parts[1]) : "443"
            return "\(host)|\(port)|\(s.avgLatency)|\(s.lossPct)|\(s.score)"
        }
        return items.isEmpty ? nil : items.joined(separator: ";")
    }

    var traffic: Int { totalTraffic }
}
