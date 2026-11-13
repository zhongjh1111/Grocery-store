//
//  PXVRTransport.swift
//  PXVR-iOS
//
//  传输层抽象：只负责「把字节体 POST 出去、做 mTLS、拿回字节响应」。
//  应用层协议（加密体、q= 包裹、s/..\ 信封、解密）在 PXVRNetwork 里处理，与传输无关。
//
//  ── TLS 指纹（JA3 / JA4）处理 ──────────────────────────────────────────────
//  Apple URLSession 的 ClientHello（密码套件顺序、扩展集合、曲线、ALPN）由系统固定，
//  与 Android（OkHttp + BoringSSL/Conscrypt）不同。若服务器按 TLS 指纹做风控，默认
//  URLSessionTransport 仍会暴露 iOS 特征。
//
//  在本环境（无 Xcode、无法编 BoringSSL）能做到的「处理」：
//   1. 把传输层抽成 PXVRTransport 协议 —— 以后换自定义 SSL 后端只改一处。
//   2. 默认走 URLSession，并显式约束 TLS 版本、不主动要 br（见 URLSessionTransport）。
//   3. 提供 BoringSSLTransport 扩展点（见文件底部），落地方式写在注释里。
//  真正复刻 Android 指纹需要把 BoringSSL 编进 App 并从 Swift 驱动 —— 那是工程级改动，
//  留作待办，需要你给 Xcode 工具链后落地。

import Foundation
import Security

protocol PXVRTransport {
    func post(baseURL: URL, path: String, body: Data, headers: [String: String]) async throws -> Data
}

// MARK: - 默认：Apple URLSession + 客户端证书(mTLS)

final class URLSessionTransport: NSObject, URLSessionDelegate, PXVRTransport {

    static let shared = URLSessionTransport()

    private let identity: SecIdentity?
    private let session: URLSession

    private override init() {
        self.identity = Self.loadClientIdentity()
        let cfg = URLSessionConfiguration.ephemeral
        // 约束到 TLS 1.2+（与 Android 一致，避免暴露实验性版本协商差异）。
        cfg.tlsMinimumSupportedProtocolVersion = .TLSv12
        // 注意：不手动设 Accept-Encoding。URLSession 对 gzip/deflate 透明解码；
        // 若我们主动写 Accept-Encoding 包含 br，服务器可能回 br，而 URLSession 解不了 br。
        self.session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    private static func loadClientIdentity() -> SecIdentity? {
        guard let url = Bundle.main.url(forResource: PXVRConstants.p12Name, withExtension: "p12"),
              let data = try? Data(contentsOf: url) else {
            PXVRLogger.warning("未找到 \(PXVRConstants.p12Name).p12")
            return nil
        }
        let options = [kSecImportExportPassphrase as String: PXVRConstants.p12Password]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let arr = items as? [[String: Any]],
              let first = arr.first,
              let raw = first[kSecImportItemIdentity as String] else {
            PXVRLogger.warning("SecPKCS12Import 失败: \(status)")
            return nil
        }
        // SecIdentity 是 CoreFoundation 类型，不能用 as? 做条件转换（编译器判定恒成功）
        return (raw as! SecIdentity)
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // 服务器证书按系统默认校验；仅在服务器要客户端证书时出示 pxvr.p12。
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate,
              let ident = identity else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let credential = URLCredential(identity: ident, certificates: nil, persistence: .forSession)
        completionHandler(.useCredential, credential)
    }

    func post(baseURL: URL, path: String, body: Data, headers: [String: String]) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw PXVRTransportError.badURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        let (data, _) = try await session.data(for: req)
        return data
    }
}

enum PXVRTransportError: Error {
    case badURL
}

// MARK: - 自定义 SSL 后端（扩展点，未实现）

/// 自定义 SSL 后端：用 BoringSSL（或 mbedTLS）替换系统 TLS，复刻 Android 的 ClientHello（JA3/JA4）。
/// 这是「让服务器按 TLS 指纹认不出 iOS」的唯一根本解法，但属于工程级改动：
///
/// 落地步骤（需在 Xcode 工程中做，本环境无工具链，故仅留扩展点）：
///   1. 把 BoringSSL 作为静态库编进 App target（或用 Carthage/SPM 引入 borealis 等封装）。
///   2. 写 C bridging header 暴露：ssl_connect / ssl_write / ssl_read / 加载客户端证书。
///   3. 握手时加载 pxvr.p12（密码见 PXVRConstants）作为客户端证书，等价于 SecIdentity。
///   4. ALPN 设成与 OkHttp 一致（"h2, http/1.1"），密码套件/曲线顺序对齐 BoringSSL 默认。
///   5. Swift 侧把加密体写入、读回响应字节，交给 PXVRNetwork 解密。
///
/// 切换时，把 PXVRNetwork 里的 `transport = URLSessionTransport.shared` 换成
/// `BoringSSLTransport()` 即可（协议一致，调用方无需改动）。
final class BoringSSLTransport: PXVRTransport {
    func post(baseURL: URL, path: String, body: Data, headers: [String: String]) async throws -> Data {
        fatalError("BoringSSLTransport 尚未实现：需将 BoringSSL 编入工程并从 Swift 驱动（见文件顶部注释）。")
    }
}
