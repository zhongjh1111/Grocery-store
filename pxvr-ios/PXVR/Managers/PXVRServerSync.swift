import Foundation
import CommonCrypto

/// PXVR 服务器同步管理器 — 对应 Android 端 oo0.java
///
/// 发现者：WorkBuddy AI
///
/// 功能：
/// 1. 密钥交换（/xk）：首次启动时向 PXVR 服务器注册，获取客户端 ID
/// 2. 配置同步（/xc）：定期上报统计数据，接收服务器配置
/// 3. 服务器列表获取：从主服务器获取可用服务器列表和配置
/// 4. 签名验证：验证服务器响应的 SHA-256 签名
///
/// 数据流：
/// - 请求：JSON → raw deflate 压缩 → 追加 0x01 → Native.call() 加密 → hex 字符串 → URL 参数 q
/// - 响应：s/{hex}\ → Native.call2() 解密 → raw inflate 解压（跳过0x01）→ JSON

class PXVRServerSync {

    static let shared = PXVRServerSync()

    /// 同步间隔（秒），对应 Android 默认 604800（7天）
    private let syncInterval: TimeInterval = 604800

    /// 客户端 ID（对应 Android ro0.D）
    /// 发现者：WorkBuddy AI
    private var clientId: String? {
        get { UserDefaults.standard.string(forKey: "pxvr_client_id") }
        set { UserDefaults.standard.set(newValue, forKey: "pxvr_client_id") }
    }

    /// 上次同步时间（对应 Android ro0.x("la_pu_s")）
    private var lastSyncTime: TimeInterval {
        get { UserDefaults.standard.double(forKey: "pxvr_last_sync") }
        set { UserDefaults.standard.set(newValue, forKey: "pxvr_last_sync") }
    }

    /// 随机数（对应 Android ro0.s("rd")）
    private var randomToken: String? {
        get { UserDefaults.standard.string(forKey: "pxvr_rd") }
        set { UserDefaults.standard.set(newValue, forKey: "pxvr_rd") }
    }

    /// 同步状态
    private var isSyncing = false

    private init() {}

    // MARK: - 公共接口

    /// 检查是否需要同步
    /// 对应 Android oo0.run() case 0 中的时间检查逻辑
    func needsSync() -> Bool {
        guard clientId != nil else { return true } // 未注册
        let elapsed = Date().timeIntervalSince1970 - lastSyncTime
        return elapsed > syncInterval
    }

    /// 执行完整同步流程
    /// 对应 Android oo0.run() case 0 的完整流程
    func sync(completion: @escaping (Result<Bool, Error>) -> Void) {
        guard !isSyncing else {
            completion(.success(false))
            return
        }
        isSyncing = true

        // 1. 确保有客户端 ID（密钥交换）
        ensureClientId { [weak self] result in
            switch result {
            case .success:
                // 2. 执行配置同步
                self?.performConfigSync { syncResult in
                    self?.isSyncing = false
                    switch syncResult {
                    case .success(let success):
                        if success {
                            self?.lastSyncTime = Date().timeIntervalSince1970
                        }
                        completion(.success(success))
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
            case .failure(let error):
                self?.isSyncing = false
                completion(.failure(error))
            }
        }
    }

    // MARK: - 密钥交换

    /// 确保客户端 ID 存在，不存在则执行密钥交换
    private func ensureClientId(completion: @escaping (Result<Void, Error>) -> Void) {
        if clientId != nil {
            completion(.success(()))
            return
        }

        print("[PXVRServerSync] 执行密钥交换 (/xk)...")

        // 对应 Android: ro0.d("{}") → b0(url + "/xk", ...)
        NetworkManager.shared.performKeyExchange { result in
            switch result {
            case .success(let id):
                print("[PXVRServerSync] 密钥交换成功，客户端 ID: \(id)")
                self.clientId = id
                completion(.success(()))
            case .failure(let error):
                print("[PXVRServerSync] 密钥交换失败: \(error.localizedDescription)")
                completion(.failure(error))
            }
        }
    }

    // MARK: - 配置同步

    /// 执行配置同步
    /// 对应 Android oo0.b() 方法
    private func performConfigSync(completion: @escaping (Result<Bool, Error>) -> Void) {
        guard let clientId = clientId else {
            completion(.failure(NSError(domain: "PXVR", code: -20, message: "无客户端 ID")))
            return
        }

        // 构建同步数据
        // 对应 Android:
        //   JSONObject put = new JSONObject().put("k", str5);
        //   put.put("r", str6).put("t", t);
        //   ro0.b(put2);  // 添加设备信息
        //   ro0.c(put2);  // 添加网络统计
        let timestamp = Int64(Date().timeIntervalSince1970)
        let rd = randomToken ?? "0"

        var syncData: [String: Any] = [
            "k": clientId,      // 客户端 ID
            "r": rd,            // 随机数
            "t": timestamp      // 时间戳
        ]

        // 添加设备信息（对应 Android ro0.b(put2)）
        addDeviceInfo(&syncData)

        // 添加应用统计（对应 Android ro0.c(put2)）
        addAppStats(&syncData)

        print("[PXVRServerSync] 执行配置同步 (/xc)...")

        NetworkManager.shared.performPXVRRequest(
            endpoint: .configSync,
            jsonData: syncData
        ) { result in
            switch result {
            case .success(let json):
                // 检查密钥是否被撤销
                // 对应 Android: if (a.optInt("krv") == 200) { 清除数据并退出 }
                if let krv = json["krv"] as? Int, krv == 200 {
                    print("[PXVRServerSync] 密钥被服务器撤销 (krv=200)，清除本地数据")
                    self.handleKeyRevocation()
                    completion(.success(false))
                    return
                }

                // 处理服务器配置
                // 对应 Android: ro0.a(a, linkedHashSet)
                self.processServerConfig(json)
                completion(.success(true))

            case .failure(let error):
                print("[PXVRServerSync] 配置同步失败: \(error.localizedDescription)")
                completion(.failure(error))
            }
        }
    }

    // MARK: - 服务器列表获取

    /// 从服务器获取配置 JSON
    /// 对应 Android oo0.run() case 0 中的服务器列表获取逻辑
    ///
    /// 流程：
    /// 1. GET https://{server}/{name}.json
    /// 2. 响应包含 "s"（签名）和 "d"（base64 编码的数据）
    /// 3. 验证签名：SHA-256(data + "PLACEHOLDER_SALT") == s
    /// 4. 解析数据为 JSON
    func fetchServerConfig(configName: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        for server in PXVRServer.allServers {
            let urlString = "https://\(server):443/\(configName).json"
            guard let url = URL(string: urlString) else { continue }

            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

            let session = URLSession.shared
            let task = session.dataTask(with: request) { data, response, error in
                guard let data = data, error == nil else {
                    continue // 尝试下一个服务器
                }

                guard let jsonString = String(data: data, encoding: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }

                // 提取签名和数据
                // 对应 Android:
                //   String s = qw0.j(jSONObject, "s");
                //   byte[] k2 = qw0.k(qw0.j(jSONObject, "d"));  // base64 decode
                //   String str6 = new String(k2, charset);
                //   验证: s.toLowerCase() == SHA256(str6 + "PLACEHOLDER_SALT")
                guard let signature = json["s"] as? String,
                      let encodedData = json["d"] as? String,
                      let decodedBytes = Data(base64Encoded: encodedData),
                      let decodedString = String(data: decodedBytes, encoding: .utf8) else {
                    continue
                }

                // 验证签名
                // 对应 Android: qw0.h((qw0.h(str6.getBytes(charset)) + "PLACEHOLDER_SALT").getBytes(charset))
                let signInput = decodedString + PXVRServer.p12Password
                let computedSig = self.sha256Hex(signInput)

                if computedSig.lowercased() == signature.lowercased() {
                    print("[PXVRServerSync] 服务器配置签名验证成功 (\(server))")

                    // 解析配置 JSON
                    if let configData = decodedString.data(using: .utf8),
                       let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] {
                        completion(.success(config))
                        return
                    }
                } else {
                    print("[PXVRServerSync] 签名验证失败 (\(server))")
                }
            }
            task.resume()
        }

        // 所有服务器都失败后（延迟调用）
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            completion(.failure(NSError(domain: "PXVR", code: -13, message: "无法获取服务器配置")))
        }
    }

    // MARK: - 私有方法

    /// 添加设备信息到同步数据
    /// 对应 Android ro0.b(JSONObject) 方法
    private func addDeviceInfo(_ data: inout [String: Any]) {
        let device = UIDevice.current
        data["dv"] = device.model
        data["os"] = "iOS"
        data["ov"] = device.systemVersion
        data["av"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        data["lang"] = Locale.current.languageCode ?? "zh"
    }

    /// 添加应用统计到同步数据
    /// 对应 Android ro0.c(JSONObject) 方法
    private func addAppStats(_ data: inout [String: Any]) {
        // 网络统计、使用时长等
        let stats = DataManager.shared.getUsageStats()
        if !stats.isEmpty {
            data["sr"] = stats
        }
    }

    /// 处理服务器返回的配置
    /// 对应 Android ro0.a(JSONObject, LinkedHashSet) 方法
    private func processServerConfig(_ config: [String: Any]) {
        // 存储服务器配置
        if let version = config["v"] as? String {
            UserDefaults.standard.set(version, forKey: "pxvr_server_version")
        }

        // 处理跳过键列表
        if let skipKeys = config["sks"] as? String {
            UserDefaults.standard.set(skipKeys, forKey: "pxvr_skip_keys")
        }

        // 更新随机数
        if let rd = config["rd"] as? String {
            randomToken = rd
        }

        print("[PXVRServerSync] 服务器配置已更新: \(config.keys.sorted())")
    }

    /// 处理密钥撤销
    /// 对应 Android oo0.b() 中 krv == 200 的处理：
    /// 清除本地数据 → System.exit(0)
    private func handleKeyRevocation() {
        // 清除客户端 ID
        clientId = nil
        UserDefaults.standard.removeObject(forKey: "pxvr_client_id")
        UserDefaults.standard.removeObject(forKey: "pxvr_last_sync")
        UserDefaults.standard.removeObject(forKey: "pxvr_rd")

        // 重置加密状态
        PXVRProtocol.shared.reset()

        print("[PXVRServerSync] 密钥已撤销，本地状态已清除")
    }

    /// SHA-256 哈希（十六进制输出）
    /// 对应 Android qw0.h(byte[]) 方法
    private func sha256Hex(_ string: String) -> String {
        let data = Array(string.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBufferPointer { ptr in
            CC_SHA256(ptr.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - UIDevice 扩展（用于设备信息）

#if !os(macOS)
import UIKit
#endif
