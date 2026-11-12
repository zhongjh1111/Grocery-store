import Foundation
import Security   // SecPKCS12Import / SecIdentity / kSecImportExportPassphrase

/// 网络请求管理器 — 对应 Android 端 ro0.java 的网络层
/// 负责调用 pixiv.net touch/ajax API（明文）和 PXVR 服务器 API（加密）
///
/// 发现者：WorkBuddy AI
///
/// 架构说明：
/// - pixiv.net API 调用：直接 HTTP GET + Cookie 认证（无加密）
/// - PXVR 服务器调用：加密通信（Native.call/call2 + PKCS#12 客户端证书）
/// - PXVR 服务器地址使用 Vigenère 密码加密，密钥 = PKCS#12 密码 = "PLACEHOLDER_SALT"

// MARK: - PXVR 服务器配置

/// PXVR 服务器端点
enum PXVREndpoint: String {
    case keyExchange = "/xk"   // 密钥交换 / 初始注册
    case configSync   = "/xc"   // 配置同步
}

/// PXVR 服务器主机（解码后的）
/// 发现者：WorkBuddy AI
/// 原始编码值在 ro0.java:136 — 使用 Vigenère 密码加密，密钥 "PLACEHOLDER_SALT"
struct PXVRServer {
    /// 主服务器（原始: !e.b00l.sx，带 ! 前缀表示需要 DNS 解析）
    static let primary = "c.example.com"
    /// 备用服务器（原始: i.b00n.rz）
    static let secondary = "example.com"
    /// 第三服务器（原始: e.pxwu.zba）
    static let tertiary = "d.pxvr.xyz"
    /// 下载服务器（原始: en.nhhf.qfu）
    static let download = "dl.ngee.net"
    /// S3 存储（原始: qzvr.v3-dddhmgrauh.cpbarocws.fpo）
    static let s3 = "pxvr.s3-accelerate.amazonaws.com"

    /// 所有服务器列表（按优先级排列）
    static let allServers = [primary, secondary, tertiary]

    /// PKCS#12 证书密码（同时也是 Vigenère 密钥）
    /// 发现者：WorkBuddy AI
    static let p12Password = "PLACEHOLDER_SALT"
    /// PKCS#12 证书别名
    static let p12Alias = "exampleWEB"

    /// Vigenère 密码解码
    /// 对应 Android ro0.n(String str) @ line 1098
    static func decodeHostname(_ encoded: String) -> String {
        let key = p12Password
        let keyChars = Array(key)
        let chars = Array(encoded)
        var result = ""

        for i in 0..<chars.count {
            let c = chars[i]
            if c >= "a" && c <= "z" {
                let shift = Int(UnicodeScalar(String(keyChars[i % keyChars.count]))!.value) % ((i % 3) + 2)
                let decoded = ((Int(c.asciiValue!) - Int(Character("a").asciiValue!) - shift + 26) % 26) + Int(Character("a").asciiValue!)
                result.append(Character(UnicodeScalar(decoded)!))
            } else {
                result.append(c)
            }
        }
        return result
    }
}

class NetworkManager: NSObject {
    static let shared = NetworkManager()

    /// pixiv.net 明文请求 session
    private let session: URLSession

    /// PXVR 服务器加密请求 session（带客户端证书）
    private var pxvrSession: URLSession?

    /// 客户端证书身份
    private var clientIdentity: SecIdentity?

    override init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.requestCachePolicy = .useProtocolCachePolicy
        self.session = URLSession(configuration: config)

        super.init()

        // 加载 PKCS#12 客户端证书
        loadClientCertificate()
    }

    // MARK: - PKCS#12 客户端证书加载

    /// 加载 PKCS#12 客户端证书
    /// 对应 Android ro0.I() 方法 @ line 282
    /// 证书文件 pxvr.p12，密码 "PLACEHOLDER_SALT"，别名 "exampleWEB"
    private func loadClientCertificate() {
        // 查找 Bundle 中的 pxvr.p12
        guard let p12Path = Bundle.main.path(forResource: "pxvr", ofType: "p12"),
              let p12Data = try? Data(contentsOf: URL(fileURLWithPath: p12Path)) else {
            print("[NetworkManager] PKCS#12 证书未找到，PXVR 服务器通信将不可用")
            return
        }

        let options: [String: Any] = [kSecImportExportPassphrase as String: PXVRServer.p12Password]

        var items: CFArray?
        let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &items)

        guard status == errSecSuccess, let cfItems = items as? [[String: Any]] else {
            print("[NetworkManager] PKCS#12 导入失败: status=\(status)")
            return
        }

        for item in cfItems {
            if let identity = item[kSecImportItemIdentity as String] as? SecIdentity {
                self.clientIdentity = identity
                print("[NetworkManager] PKCS#12 客户端证书加载成功")

                // 创建带客户端证书的 URLSession
                let config = URLSessionConfiguration.default
                config.timeoutIntervalForRequest = 30
                config.timeoutIntervalForResource = 300
                self.pxvrSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                break
            }
        }
    }

    // MARK: - Pixiv API（明文，直接调用 pixiv.net）

    /// 获取插画详情
    /// 对应 Android: touch/ajax/illust/details?illust_id=
    func fetchIllustDetail(illustId: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let urlString = "https://www.pixiv.net:443/touch/ajax/illust/details?illust_id=\(illustId)&lang=zh"
        guard let url = URL(string: urlString) else {
            completion(.failure(NSError(domain: "PXVR", code: -1, message: "Invalid URL")))
            return
        }
        performPixivRequest(url: url, referrer: "https://www.pixiv.net/artworks/\(illustId)", completion: completion)
    }

    /// 批量获取插画详情
    /// 对应 Android: touch/ajax/illust/details/many
    func fetchIllustDetailsMany(illustIds: [String], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let idsParam = illustIds.joined(separator: "&illust_ids[]=")
        let urlString = "https://www.pixiv.net:443/touch/ajax/illust/details/many?illust_ids[]=\(idsParam)&lang=zh"
        guard let url = URL(string: urlString) else {
            completion(.failure(NSError(domain: "PXVR", code: -1, message: "Invalid URL")))
            return
        }
        performPixivRequest(url: url, referrer: "https://www.pixiv.net/", completion: completion)
    }

    /// 获取小说详情
    /// 对应 Android: touch/ajax/novel/details?novel_id=
    func fetchNovelDetail(novelId: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let urlString = "https://www.pixiv.net:443/touch/ajax/novel/details?novel_id=\(novelId)&lang=zh"
        guard let url = URL(string: urlString) else {
            completion(.failure(NSError(domain: "PXVR", code: -1, message: "Invalid URL")))
            return
        }
        performPixivRequest(url: url, referrer: "https://www.pixiv.net/novel/show.php?id=\(novelId)", completion: completion)
    }

    /// 获取小说系列
    /// 对应 Android: touch/ajax/novel/series/
    func fetchNovelSeries(seriesId: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let urlString = "https://www.pixiv.net:443/touch/ajax/novel/series/\(seriesId)?lang=zh"
        guard let url = URL(string: urlString) else {
            completion(.failure(NSError(domain: "PXVR", code: -1, message: "Invalid URL")))
            return
        }
        performPixivRequest(url: url, referrer: "https://www.pixiv.net/novel/series/\(seriesId)", completion: completion)
    }

    /// 获取小说系列内容
    /// 对应 Android: touch/ajax/novel/series_content/
    func fetchNovelSeriesContent(seriesId: String, page: Int = 1, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let urlString = "https://www.pixiv.net:443/touch/ajax/novel/series_content/\(seriesId)?p=\(page)&lang=zh"
        guard let url = URL(string: urlString) else {
            completion(.failure(NSError(domain: "PXVR", code: -1, message: "Invalid URL")))
            return
        }
        performPixivRequest(url: url, referrer: "https://www.pixiv.net/novel/series/\(seriesId)", completion: completion)
    }

    /// 获取小说中的插图
    /// 对应 Android: ajax/novel/.../insert_illusts
    func fetchNovelInsertIllusts(novelId: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let urlString = "https://www.pixiv.net:443/ajax/novel/\(novelId)/insert_illusts?lang=zh"
        guard let url = URL(string: urlString) else {
            completion(.failure(NSError(domain: "PXVR", code: -1, message: "Invalid URL")))
            return
        }
        performPixivRequest(url: url, referrer: "https://www.pixiv.net/novel/show.php?id=\(novelId)", completion: completion)
    }

    // MARK: - PXVR 服务器 API（加密）

    /// 向 PXVR 服务器发送加密请求
    /// 对应 Android oo0.b() 方法 + ro0.b0() + ro0.d()
    ///
    /// 流程：
    /// 1. JSON → 压缩(raw deflate) → 追加0x01 → Native.call() → hex 字符串
    /// 2. 将 hex 字符串作为 URL 查询参数 q 发送
    /// 3. 响应中包含 s/{hex_data}\ 格式的加密数据
    /// 4. 提取 hex 数据 → Native.call2() → 解压 → JSON
    ///
    /// - Parameters:
    ///   - endpoint: PXVR 服务器端点（/xk 或 /xc）
    ///   - jsonData: 要发送的 JSON 数据
    ///   - host: 服务器主机（用于 Host 头，可选）
    ///   - completion: 结果回调
    func performPXVRRequest(
        endpoint: PXVREndpoint,
        jsonData: [String: Any],
        host: String? = nil,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        // 1. 加密请求数据
        guard let encryptedHex = PXVRProtocol.shared.encodeJSON(jsonData) else {
            completion(.failure(NSError(domain: "PXVR", code: -10, message: "加密请求失败")))
            return
        }

        // 2. 尝试每个服务器
        let servers = PXVRServer.allServers
        var serverIndex = 0

        func tryNextServer() {
            guard serverIndex < servers.count else {
                completion(.failure(NSError(domain: "PXVR", code: -11, message: "所有 PXVR 服务器均不可用")))
                return
            }

            let server = servers[serverIndex]
            serverIndex += 1

            // 构建 URL：https://{server}/{endpoint}.json?q={encryptedHex}
            // 对应 Android: ro0.b0(str2 + "/xc", str3, new gu(arrayList, arrayList2))
            // gu 中包含 q=encryptedHex 查询参数
            var components = URLComponents()
            components.scheme = "https"
            components.host = server
            components.port = 443
            components.path = "/\(endpoint.rawValue).json"
            components.queryItems = [
                URLQueryItem(name: "q", value: encryptedHex)
            ]

            guard let url = components.url else {
                tryNextServer()
                return
            }

            print("[NetworkManager] PXVR 请求: \(server)\(endpoint.rawValue) (server \(serverIndex)/\(servers.count))")

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

            // 设置 Host 头（对应 Android b0() 中的 Host header）
            if let host = host {
                request.setValue(host, forHTTPHeaderField: "Host")
            }

            // 使用带客户端证书的 session
            let sessionToUse = pxvrSession ?? self.session

            let task = sessionToUse.dataTask(with: request) { data, response, error in
                if let error = error {
                    print("[NetworkManager] PXVR 请求失败 (\(server)): \(error.localizedDescription)")
                    tryNextServer()
                    return
                }

                guard let data = data, let responseString = String(data: data, encoding: .utf8) else {
                    print("[NetworkManager] PXVR 响应为空 (\(server))")
                    tryNextServer()
                    return
                }

                // 3. 解析响应中的加密数据
                // 对应 Android oo0.a(String str): 提取 s/ 和 \ 之间的字符串
                guard let extractedHex = self.extractEncryptedData(from: responseString) else {
                    print("[NetworkManager] PXVR 响应格式无效 (\(server)): \(responseString.prefix(200))")
                    tryNextServer()
                    return
                }

                // 4. 解密响应
                // 对应 Android oo0.a(): Native.call2(substring) → Inflater → JSON
                guard let json = PXVRProtocol.shared.decodeJSON(extractedHex) else {
                    print("[NetworkManager] PXVR 解密失败 (\(server))")
                    tryNextServer()
                    return
                }

                // 5. 验证结果
                // 对应 Android: "ok".equals(jSONObject.getString("result"))
                if let result = json["result"] as? String, result == "ok" {
                    print("[NetworkManager] PXVR 请求成功 (\(server))")
                    completion(.success(json))
                } else {
                    print("[NetworkManager] PXVR 响应 result 非 ok (\(server)): \(json)")
                    completion(.success(json)) // 仍然返回数据，让调用方判断
                }
            }
            task.resume()
        }

        tryNextServer()
    }

    /// 从 PXVR 服务器响应中提取加密数据
    /// 对应 Android oo0.a(String str): 查找 "s/" 和 "\" 之间的字符串
    ///
    /// 响应格式: ...s/{hex_encoded_encrypted_data}\...
    private func extractEncryptedData(from response: String) -> String? {
        // 对应 Android: mr0.k0(str, "s/", 0, 6) 和 mr0.j0(str, '\\', 0, 6)
        guard let sRange = response.range(of: "s/") else { return nil }
        let afterS = response[sRange.upperBound...]
        guard let backslashRange = afterS.range(of: "\\") else { return nil }

        let hexData = String(afterS[..<backslashRange.lowerBound])

        guard !hexData.isEmpty else { return nil }
        return hexData
    }

    // MARK: - PXVR 密钥交换

    /// 执行密钥交换（初始注册）
    /// 对应 Android oo0.b() 中 str5 == null 时的流程:
    ///   ro0.d("{}") → b0(url + "/xk", ...) → a(response) → 获取 id
    func performKeyExchange(completion: @escaping (Result<String, Error>) -> Void) {
        performPXVRRequest(endpoint: .keyExchange, jsonData: [:]) { result in
            switch result {
            case .success(let json):
                // 对应 Android: str5 = qw0.j(a2, "id")
                if let id = json["id"] as? String {
                    completion(.success(id))
                } else {
                    completion(.failure(NSError(domain: "PXVR", code: -12, message: "密钥交换响应缺少 id 字段")))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - Image Download

    /// 下载图片 (需要 Referer: https://www.pixiv.net/)
    func downloadImage(url: String, cookie: String?, saveTo directory: FileManager.SearchPathDirectory = .documentDirectory, completion: @escaping (Result<URL, Error>) -> Void) {
        guard let imageURL = URL(string: url) else {
            completion(.failure(NSError(domain: "PXVR", code: -1, message: "Invalid URL")))
            return
        }

        var request = URLRequest(url: imageURL)
        request.setValue("https://www.pixiv.net/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        if let cookie = cookie {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data, !data.isEmpty else {
                completion(.failure(NSError(domain: "PXVR", code: -2, message: "No data")))
                return
            }

            let docsDir = FileManager.default.urls(for: directory, in: .userDomainMask)[0]
            let pxvrDir = docsDir.appendingPathComponent("PXVR", isDirectory: true)
            try? FileManager.default.createDirectory(at: pxvrDir, withIntermediateDirectories: true)

            let ext = imageURL.pathExtension.isEmpty ? "jpg" : imageURL.pathExtension
            let filename = "\(UUID().uuidString).\(ext)"
            let fileURL = pxvrDir.appendingPathComponent(filename)

            do {
                try data.write(to: fileURL)
                completion(.success(fileURL))
            } catch {
                completion(.failure(error))
            }
        }
        task.resume()
    }

    // MARK: - Private

    /// 执行 pixiv.net 明文 API 请求
    /// 对应 Android wh0.f() 方法 — 直接 HTTP GET + Cookie
    private func performPixivRequest(url: URL, referrer: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        var request = URLRequest(url: url)
        request.setValue("https://www.pixiv.net", forHTTPHeaderField: "Origin")
        request.setValue(referrer, forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

        // 注入 Cookie
        if let cookie = CookieManager.shared.getPixivCookie() {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data else {
                completion(.failure(NSError(domain: "PXVR", code: -2, message: "No response data")))
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let body = json["body"] as? [String: Any] {
                        completion(.success(body))
                    } else {
                        completion(.success(json))
                    }
                } else {
                    completion(.failure(NSError(domain: "PXVR", code: -3, message: "Invalid JSON")))
                }
            } catch {
                completion(.failure(error))
            }
        }
        task.resume()
    }
}

// MARK: - URLSessionDelegate（客户端证书认证）

extension NetworkManager: URLSessionDelegate {

    /// TLS 客户端证书认证
    /// 对应 Android ro0.I() 方法 — 加载 PKCS#12 证书用于双向 TLS
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // 处理客户端证书认证（双向 TLS）
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate {
            if let identity = clientIdentity {
                // 对应 Android: keyStore.getEntry("exampleWEB", ...)
                let credential = URLCredential(identity: identity, certificates: nil, persistence: .forSession)
                completionHandler(.useCredential, credential)
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
            return
        }

        // 服务器证书验证 — 信任（简化处理）
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            if let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
            return
        }

        completionHandler(.performDefaultHandling, nil)
    }
}

// MARK: - NSError Helper

extension NSError {
    convenience init(domain: String, code: Int, message: String) {
        self.init(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
