//
//  PXVRNetwork.swift
//  PXVR-iOS
//
//  网络层 —— 应用协议：/xk + /xc + 通用 API。
//  服务端协议（路径、加密传输、q= 包裹、s/..\ 信封、krv 吊销）锁死，必须与 Android 一致。
//
//  关键格式（来自 APK 逆向，务必保持）：
//   · 请求：POST，Content-Type = application/x-www-form-urlencoded，包体 = "q=" + 加密hex
// （Android 用 gu 把加密串写成名为 "q" 的表单项；见 Android 端 / gu）。
// · 响应：被包裹在 s/<加密hex>\ 中（Android 端 提取 "s/" 与首个 "\" 之间的 hex 再解密）。
//   · /xk 发空 {} -> 服务器下发设备 key（响应字段 "id"）。
//   · /xc 上报 k/r/t + c/v/s/m/d/wv；krv=200 -> 清库 + exit(0)（服务器吊销，保持原语义）。

import Foundation
import WebKit

final class PXVRNetwork {

    /// 设备标记（对应 Android 的 dm）。默认 0 = 未 root / 未越狱。
    var deviceFlag: Int = 0

    static let shared = PXVRNetwork()

    /// 传输层（默认 URLSession；换成 BoringSSLTransport 即可切自定义 SSL，见 PXVRTransport.swift）。
    private let transport: PXVRTransport

    /// /xk 下发的设备 key（服务器签发，不绑硬件）。后续请求（/xc 的 k）必须携带，保持会话自洽。
    private(set) var deviceKey: String?

    init(transport: PXVRTransport = URLSessionTransport.shared) {
        self.transport = transport
    }

    // MARK: - 应用层：加密体 + q= 包裹 + 信封剥离

    /// 通用加密 API 调用。payload 为明文 JSON 字典，内部加密后按 q= 表单 POST，
    /// 响应剥离 s/..\ 信封后解密。所有业务接口（/xk、/xc 及后续内容接口）共用此路径。
    func callAPI(baseURL: URL, path: String, payload: [String: Any]) async -> [String: Any]? {
        guard let enc = PXVRProtocol.shared.encodeJSON(payload) else {
            PXVRLogger.warning("\(path) 加密失败")
            return nil
        }
        // 与 Android gu 一致：包体 = "q=" + 加密hex（hex 仅 [0-9a-f]，表单安全）。
        let body = ("q=" + enc).data(using: .utf8)!
        var headers: [String: String] = [
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": PXVRRequestProfile.userAgent,
        ]
        for (k, v) in PXVRRequestProfile.extraHeaders { headers[k] = v }

        do {
            // 网络抖动时重试 3 次，退避 0.8s / 1.6s。
            // 只重试传输层错误；解密失败不重试（重发同样的包结果一样）。
            var lastError: Error?
            var data = Data()
            for attempt in 1...3 {
                do {
                    data = try await transport.post(baseURL: baseURL, path: path, body: body, headers: headers)
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    PXVRLogger.warning("\(path) 第 \(attempt) 次尝试失败: \(error.localizedDescription)")
                    if attempt < 3 {
                        try? await Task.sleep(nanoseconds: UInt64(attempt) * 800_000_000)
                    }
                }
            }
            if let e = lastError { throw e }
            guard let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                PXVRLogger.warning("\(path) 响应非 UTF-8 文本")
                return nil
            }
            // 有些端点直接回明文 JSON（实测 /um 登录成功返回 {"r":0}，失败 {"r":1}），
            // 没有 s/..\ 信封，强行解密会报「hex 非法」。
            if raw.hasPrefix("{"), let d = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                return obj
            }
            // 剥离 s/<hex>\ 信封（Android 端），取不到则原样当 hex（防御其它端点）。
            let hex = Self.extractEnvelopeHex(raw) ?? raw
            guard let resp = PXVRProtocol.shared.decodeJSON(hex) else {
                PXVRLogger.warning("\(path) 响应解密失败（已尝试剥离 s/..\\ 信封）")
                return nil
            }
            return resp
        } catch {
            PXVRLogger.warning("\(path) 请求失败: \(error)")
            return nil
        }
    }

    /// 对应 Android 端：从 `s/<hex>\` 信封中提取加密 hex。找不到 `s/` 则返回 nil（交给调用方原样处理）。
    private static func extractEnvelopeHex(_ raw: String) -> String? {
        guard let sRange = raw.range(of: "s/") else { return nil }
        let after = raw[sRange.upperBound...]
        guard let back = after.firstIndex(of: "\\") else { return nil }
        return String(after[..<back])
    }

    // MARK: - /xk 设备 key

    /// 对应 Android 端的 /xk：发空 {} 拿服务器下发的设备 key（响应字段 "id"，不绑硬件）。
    func performXK(baseURL: URL) async -> String? {
        let resp = await callAPI(baseURL: baseURL, path: PXVRConstants.pathDeviceKey, payload: [:])
        if let id = resp?["id"] as? String, !id.isEmpty {
            self.deviceKey = id
            Self.storeKey(id)
            return id
        }
        PXVRLogger.warning("/xk 未返回设备 key（字段 \"id\"）")
        return nil
    }

    // MARK: - /xc 设备认证 + 上报

    /// 对应 Android 端的 /xc 上报。完整字段（fresh 客户端、无进行中下载时）：
    /// k = /xk 下发的设备 key（响应字段 "id"），r = rd||"0"，t = Android 端（首次运行未建立信任时为 0），
    /// c/v/s/m/d/wv 由 Android 端 填充。f/sr 字段仅在存在进行中下载时由 Android 端/c 添加，此处省略。
    /// krv=200 -> 清库 + exit(0)（服务器吊销，保持原语义）。
    @discardableResult
    func performXC(baseURL: URL) async -> [String: Any]? {
        guard let key = self.deviceKey, !key.isEmpty else {
            PXVRLogger.warning("/xc 缺少设备 key（应先完成 /xk）")
            return nil
        }
        let p = PXVRDeviceProfile.shared
        // 服务端下发的登记号要原样回传（原版 ws0.t("rd")）
        let rd = UserDefaults.standard.string(forKey: "pxvr.rd") ?? "0"
        let reportStatsOn = (UserDefaults.object(forKey: "pxvr.reportStats") as? Bool) ?? true
        let stats = PXVRNodeStats.shared
        var payload: [String: Any] = [
            "k": key,                       // 设备 key（/xk 下发的 "id"），服务端依此关联会话
            "r": reportStatsOn ? rd : "0",  // 默认回退 v74 行为
            "t": reportStatsOn ? stats.traffic : 0,   // 累计流量，原版 ws0.u()
            "c": "wd",
            "v": p.appVersion,              // 对应 Android v 字段（原始 APK 上报 20260606）
            "s": p.sdkInt,                  // 对应 Build.VERSION.SDK_INT
            "m": p.deviceString,            // MANUFACTURER + " " + MODEL（注意空格，与 Android 端一致）
            "d": self.deviceFlag,          // 对应 dm 标记；干净 iOS 设备为 0，与未 root 的 Android 一致
            "wv": p.webViewVersion          // iOS 上无 net.ngee.wv 伴生 APK，固定 ""
        ]
        // 节点质量上报（原版 ws0.b() / ws0.c()），服务端据此调度路线。
        // 默认关闭：v31 实测怀疑这几个字段触发了服务端的风控（回 krv=200 直接退出）。
        // 调试页可打开验证：UserDefaults 设 pxvr.reportStats = true
        let reportStats = (UserDefaults.object(forKey: "pxvr.reportStats") as? Bool) ?? true
        if reportStats {
            if let f = stats.reportF() { payload["f"] = f }
            if let sr = stats.reportSR() { payload["sr"] = sr }
        }
        guard let resp = await callAPI(baseURL: baseURL, path: PXVRConstants.pathDeviceAuth, payload: payload) else {
            return nil
        }
        // 实证联调：把服务器明文响应打出来，看它是否接受 / 起疑 / 吊销。
        PXVRLogger.info("[xc] 服务器响应: \(resp)")
        if let rd = resp["rd"] as? String, !rd.isEmpty {
            UserDefaults.standard.set(rd, forKey: "pxvr.rd")
            PXVRLogger.info("[xc] 记录登记号 rd=\(rd)")
        }
        // 落盘一份，万一触发杀开关退出，重启后还能查到当时服务端回的是什么
        Self.persistLastXC(resp)
        if let krv = resp["krv"] as? Int, krv == 200 {
            PXVRLogger.warning("/xc 收到吊销指令 krv=200，清库并退出")
            Self.clearLocalData()
            exit(0)
        }
        return resp
    }

    /// 通用接口调用：`/<path>?k=<key>&<params>`，体为空。
    /// 对应原版 ws0.p0(name, params, cb)。
    func call(_ path: String, params: [(String, String)], baseURL: URL) async -> [String: Any]? {
        guard let key = deviceKey, !key.isEmpty else {
            PXVRLogger.warning("\(path) 需要设备 key")
            return nil
        }
        var items: [URLQueryItem] = [URLQueryItem(name: "k", value: key)]
        for (n, v) in params { items.append(URLQueryItem(name: n, value: v)) }
        var comps = URLComponents()
        comps.path = "/" + path
        comps.queryItems = items
        let q = comps.string ?? "/\(path)"
        let resp = await callAPI(baseURL: baseURL, path: q, payload: [:])
        PXVRLogger.info("/\(path) 响应: \(String(describing: resp))")
        return resp
    }

    /// 同 `call`，但允许响应是 JSON 数组（/msg 就是数组）
    func callRaw(_ path: String, params: [(String, String)], baseURL: URL) async -> Any? {
        guard let key = deviceKey, !key.isEmpty else { return nil }
        var items: [URLQueryItem] = [URLQueryItem(name: "k", value: key)]
        for (n, v) in params { items.append(URLQueryItem(name: n, value: v)) }
        var comps = URLComponents()
        comps.path = "/" + path
        comps.queryItems = items
        let q = comps.string ?? "/\(path)"

        guard let enc = PXVRProtocol.shared.encodeJSON([:]) else { return nil }
        let body = ("q=" + enc).data(using: .utf8)!
        var headers: [String: String] = [
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": PXVRRequestProfile.userAgent,
        ]
        for (k, v) in PXVRRequestProfile.extraHeaders { headers[k] = v }

        do {
            let data = try await transport.post(baseURL: baseURL, path: q, body: body, headers: headers)
            guard let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            if let d = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) {
                return obj
            }
            if let hex = Self.extractEnvelopeHex(raw),
               let resp = PXVRProtocol.shared.decodeJSON(hex) { return resp }
            return nil
        } catch {
            PXVRLogger.warning("\(path) 请求失败: \(error)")
            return nil
        }
    }

    /// 把最近一次 /xc 明文响应写到 Documents，便于退出后排查
    private static func persistLastXC(_ resp: [String: Any]) {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("last-xc.json")
        if let data = try? JSONSerialization.data(withJSONObject: resp, options: [.prettyPrinted]) {
            try? data.write(to: url)
        }
    }

    /// 设备 key 持久化（对应原版 ws0.q0("k", ...) / ws0.t("k")）
    private static let keyStoreKey = "pxvr.deviceKey"

    private static func storedKey() -> String? {
        let v = UserDefaults.standard.string(forKey: keyStoreKey)
        return (v?.isEmpty == false) ? v : nil
    }

    private static func storeKey(_ k: String) {
        UserDefaults.standard.set(k, forKey: keyStoreKey)
    }

    static func clearStoredKey() {
        UserDefaults.standard.removeObject(forKey: keyStoreKey)
    }

    /// 完整握手。对应原版 ps0：
    ///   内存有 key → 直接用；本地存有 key → 直接用；
    ///   都没有才 /xk，拿到后写盘。**有 key 就永不再发 /xk。**
    func handshake(baseURL: URL) async -> (page: String?, config: [String: Any]?) {
        // ① 复用已有 key，跳过 /xk
        if deviceKey == nil, let saved = Self.storedKey() {
            deviceKey = saved
            PXVRLogger.info("[net] 复用已存设备 key \(saved.prefix(12))…")
        }

        if deviceKey != nil, let cfg = await performXC(baseURL: baseURL),
           (cfg["result"] as? String) == "ok" {
            let page = (cfg["mp"] as? String) ?? (cfg["hp"] as? String)
            PXVRLogger.info("/xc 成功（复用设备 key），主页面 = \(page ?? "<未下发>")")
            return (page, cfg)
        }

        // ② key 不存在或已失效 → 重新 /xk
        if deviceKey != nil {
            PXVRLogger.info("[net] 已存 key 失效，重新 /xk")
        }
        deviceKey = nil
        guard let key = await performXK(baseURL: baseURL) else {
            PXVRLogger.warning("握手中断：/xk 失败")
            return (nil, nil)
        }
        PXVRLogger.info("/xk 成功，设备 key = \(key)")
        Self.storeKey(key)

        guard let cfg = await performXC(baseURL: baseURL) else {
            PXVRLogger.warning("握手中断：/xc 失败")
            return (nil, nil)
        }
        let page = (cfg["mp"] as? String) ?? (cfg["hp"] as? String)
        PXVRLogger.info("/xc 成功，主页面 = \(page ?? "<未下发>")")
        return (page, cfg)
    }

    /// 登录。对应原版 `ws0.p0("um", [a=l, m, p], cb)`：
    /// `POST <base>/um?k=<设备key>`，body 仍是加密的 `q=`。
    /// `a`: "l" 登录 / "r" 注册（注册还要带 `ic` 邀请码）
    func login(baseURL: URL,
               email: String,
               password: String,
               action: String = "l",
               inviteCode: String? = nil) async -> [String: Any]? {
        guard let key = deviceKey, !key.isEmpty else {
            PXVRLogger.warning("/um 需要先完成 /xk")
            return nil
        }
        // 实测：/um 的账号参数必须在 **query** 里，放加密体会被忽略（返回 {"r":1}）。
        // 体只发空对象。
        var items: [URLQueryItem] = [
            URLQueryItem(name: "k", value: key),
            URLQueryItem(name: "a", value: action),
            URLQueryItem(name: "m", value: email),
        ]
        if action == "l" { items.append(URLQueryItem(name: "p", value: password)) }
        if let ic = inviteCode, !ic.isEmpty { items.append(URLQueryItem(name: "ic", value: ic)) }

        var comps = URLComponents()
        comps.path = "/um"
        comps.queryItems = items
        let path = comps.string ?? "/um?k=\(key)"
        PXVRLogger.info("提交登录 → \(path.prefix(60))")
        let resp = await callAPI(baseURL: baseURL, path: path, payload: [:])
        PXVRLogger.info("/um 响应: \(String(describing: resp))")
        return resp
    }

    /// 按顺序尝试多个服务器，返回第一个握手成功的。
    /// 对应原版 `ws0.x` 列表 + `ps0.run()` 里的逐个探测逻辑。
    func handshake(servers: [URL]) async -> (page: String?, config: [String: Any]?, base: URL?) {
        guard !servers.isEmpty else {
            PXVRLogger.warning("没有可用服务器地址")
            return (nil, nil, nil)
        }
        // 上次成功的服务器排最前，避免每次启动都白撞失败节点
        var ordered = servers
        if let cached = UserDefaults.standard.string(forKey: "pxvr.lastServer"),
           let idx = ordered.firstIndex(where: { $0.absoluteString == cached }), idx > 0 {
            ordered.remove(at: idx)
            ordered.insert(servers[idx], at: 0)
            PXVRLogger.info("[net] 优先使用上次成功的服务器 \(cached)")
        }

        for (i, base) in ordered.enumerated() {
            PXVRLogger.info("[\(i + 1)/\(ordered.count)] 尝试 \(base.absoluteString)")
            let r = await handshake(baseURL: base)
            if let cfg = r.config, (cfg["result"] as? String) == "ok" {
                PXVRLogger.info("服务器可用：\(base.absoluteString)")
                UserDefaults.standard.set(base.absoluteString, forKey: "pxvr.lastServer")
                return (r.page, cfg, base)
            }
            PXVRLogger.warning("跳过：\(base.absoluteString)")
        }
        PXVRLogger.warning("所有服务器均不可用")
        return (nil, nil, nil)
    }

    // MARK: - 真机联调：发一个包看服务器是否起疑

    /// 用户验证方法：用一台真 iOS 设备发一个包，观察服务器反应。
    /// 依次完成 /xk（拿设备 key）+ /xc（上报），并把完整明文响应打到日志。
    /// 若日志显示服务器正常返回、无 krv=200、无错误，说明设备画像暂不查，可维持真实 iOS 值；
    /// 若被拒 / 被标识，再把 PXVRDeviceProfile.shared.spoofAndroid 设为 true。
    func runHandshakeDiagnostic(baseURL: URL) {
        let p = PXVRDeviceProfile.shared
        PXVRLogger.info("[diag] 设备画像: m=\(p.deviceString) s=\(p.sdkInt) wv=\(p.webViewVersion) v=\(p.appVersion) d=\(self.deviceFlag) spoof=\(p.spoofAndroid)")
        Task {
            let xk = await performXK(baseURL: baseURL)
            PXVRLogger.info("[diag] /xk -> deviceKey(k)=\(xk ?? "<nil>")")
            await performXC(baseURL: baseURL)
            PXVRLogger.info("[diag] 完成：观察上面 [xc] 服务器响应即可判断服务器是否起疑")
        }
    }

    // MARK: - 辅助

    private static func clearLocalData() {
        // 对应 Android 清库（ObjectBox deleteAll + System.exit）。
        // iOS 当前本地存储：UserDefaults + WKWebView Cookie；按实际存储实现补充 Keychain / 文件清理。
        let domain = Bundle.main.bundleIdentifier ?? "net.ngee.pxvr"
        UserDefaults.standard.removePersistentDomain(forName: domain)
        let cookieStore = WKWebsiteDataStore.default().httpCookieStore
        cookieStore.getAllCookies { cookies in
            for c in cookies { cookieStore.delete(c) }
        }
        // Keychain / 文件缓存清理按实际实现补充。
    }
}
