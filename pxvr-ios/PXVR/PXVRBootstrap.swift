//
//  PXVRBootstrap.swift
//  PXVR-iOS
//
//  启动期的「配置名派生 → 远端配置拉取 → 签名校验」链路。
//
//  这一段完全由本地计算 + 一次 HTTPS GET 构成，不依赖 libnative-lib.so，
//  也不依赖 APK，因此可以先于加密层落地。
//
//  实测依据（见 PROTOCOL-LIVE-VERIFIED.md）：
//    configName = SHA1( signerCertSHA1Hex + packageName + salt )
//                 -> <40 bytes hex>
//    GET https://example.com/{configName}.json
//        -> {"d": "<hex>", "s": "<sig>"}
//    校验 s == SHA1_hex( SHA1_hex( bytes.fromhex(d) ) + salt )
//    明文 = json.loads(bytes.fromhex(d))  -> {"s": base, "s0": host, "v": ver, ...}
//
//  与 Android 的对应关系：
//    configName  <- 本地按签名证书算出，不走网络（无 mTLS）
//    该 URL 的 Host 是 example.com，是整个体系里唯一不加密的入口，其余全走信封
//

import Foundation
import CryptoKit

// MARK: - 派生与签名

enum PXVRBootstrap {

    // MARK: 常量

    /// 与 Android 保持一致的包名。iOS 侧 bundleId 相同（project.yml 已设）。
    static let packageName = "net.ngee.pixiver"

    /// 签名证书 SHA-1（DER）。Android 从 PackageManager 取，iOS 侧为固定移植常量。
    static let signerCertSHA1Hex = "0000000000000000000000000000000000000000"

    /// 12 字符盐。以字符码构造，避免在源码里出现明文常量。
    static let salt: String = {
        let codes: [UInt32] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]   // 脱敏
        return String(codes.map { Character(UnicodeScalar($0)!) })
    }()

    /// 配置分发主机（明文入口）。
    static let configHost = "example.com"

    /// 已知的期望值，用于启动自检。若派生结果不符，说明证书或包名被改动。
    static let expectedConfigName = "0000000000000000000000000000000000000000000000000000000000000000"

    // MARK: configName

    /// configName = SHA1(证书SHA1 + 包名 + 盐)。
    static func configName(cert: String = signerCertSHA1Hex,
                           pkg: String = packageName,
                           salt: String = salt) -> String {
        sha1Hex(Data((cert + pkg + salt).utf8))
    }

    /// 自检：派生值必须等于实测值。失败说明移植常量错了。
    @discardableResult
    static func selfCheck() -> Bool {
        let derived = configName()
        let ok = derived == expectedConfigName
        if ok {
            PXVRLogger.info("[bootstrap] configName 自检通过: \(derived)")
        } else {
            PXVRLogger.warning("[bootstrap] configName 自检失败: 派生 \(derived)，期望 \(expectedConfigName)")
        }
        return ok
    }

    // MARK: 签名校验

    /// 校验远端配置签名：s == SHA1_hex( SHA1_hex(payloadBytes) + salt )
    /// 注意内层是把 SHA1 的 **hex 字符串** 再拼盐，而不是二进制。
    static func verifySignature(payload: Data, signatureHex: String,
                                salt: String = salt) -> Bool {
        let inner = sha1Hex(payload)                                   // hex 字符串
        let outer = sha1Hex(Data((inner + salt).utf8))                 // hex(hex + salt)
        let expected = outer.lowercased()
        let actual = signatureHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ok = expected == actual
        if !ok {
            PXVRLogger.warning("[bootstrap] 配置签名不匹配: 期望 \(expected.prefix(16))… 实得 \(actual.prefix(16))…")
        }
        return ok
    }

    // MARK: 远端配置

    struct RemoteConfig {
        /// 认证后的主接入点（实测形如 https://203.0.113.1:50443）
        let base: String
        /// 主机名形式
        let baseHost: String?
        /// 协议版本号
        let version: Int
        /// 原始明文 JSON，供后续字段按需读取
        let raw: [String: Any]
    }

    enum BootstrapError: LocalizedError {
        case badURL
        case httpStatus(Int)
        case malformedJSON
        case signatureMismatch
        case decodeFailed

        var errorDescription: String? {
            switch self {
            case .badURL:              return "配置 URL 构造失败"
            case .httpStatus(let c):   return "配置请求 HTTP \(c)"
            case .malformedJSON:       return "配置响应不是预期的 {d,s} 结构"
            case .signatureMismatch:   return "配置签名校验失败"
            case .decodeFailed:        return "配置载荷解码/解析失败"
            }
        }
    }

    /// 拉取远端配置。
    /// - Parameter session: 便于测试注入；默认用 ephemeral 且不走缓存。
    static func fetchRemoteConfig(session: URLSession = .shared) async throws -> RemoteConfig {
        let name = configName()
        guard let url = URL(string: "https://\(configHost)/\(name).json") else {
            throw BootstrapError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // 该端点返回的是纯 JSON 文本；显式要求 identity，避免中间层换成 br 之类
        // 客户端不认识的编码（信封接口上踩过同样的坑）。
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BootstrapError.httpStatus(http.statusCode)
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dHex = root["d"] as? String,
              let sig = root["s"] as? String else {
            throw BootstrapError.malformedJSON
        }

        guard let payload = Data(hexString: dHex) else {
            throw BootstrapError.decodeFailed
        }

        guard verifySignature(payload: payload, signatureHex: sig) else {
            throw BootstrapError.signatureMismatch
        }

        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw BootstrapError.decodeFailed
        }

        let base = (obj["s"] as? String) ?? ""
        let baseHost = obj["s0"] as? String
        let version = (obj["v"] as? Int) ?? (obj["v"] as? NSNumber)?.intValue ?? 0

        PXVRLogger.info("[bootstrap] 配置拉取成功 base=\(base) host=\(baseHost ?? "-") v=\(version)")
        return RemoteConfig(base: base, baseHost: baseHost, version: version, raw: obj)
    }

    // MARK: 工具

    /// SHA1 的十六进制小写字符串（CryptoKit）。
    static func sha1Hex(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Data hex

extension Data {
    /// 从十六进制字符串解码；长度为奇数或含非法字符时返回 nil。
    init?(hexString: String) {
        let s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count % 2 == 0, !s.isEmpty else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let b = UInt8(s[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        self = Data(bytes)
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
