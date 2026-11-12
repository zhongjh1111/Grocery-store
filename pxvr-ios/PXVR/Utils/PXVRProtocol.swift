//
//  PXVRProtocol.swift
//  PXVR-iOS
//
//  PXVR v20261028R 网络协议 —— 完整实现。
//  规范见 PROTOCOL-SPEC.md；参考实现见仓库根目录 pxvr_proto.py；验收向量见 testvectors.json。
//
//  依赖：CommonCrypto（AES-ECB / AES-CBC）、CryptoKit（SHA-256）、
//        Security（RSA 裸运算）、zlib（raw deflate / inflate，经桥接头引入）。
//

import Foundation
import CommonCrypto
import CryptoKit
import Security

enum PXVRProtocolError: Error, CustomStringConvertible {
    case rsaKeyImportFailed(String)
    case rsaOperationFailed
    case aesFailed(Int32)
    case deflateFailed(Int32)
    case inflateFailed(Int32)
    case badResponseHeader
    case badPadding

    var description: String {
        switch self {
        case .rsaKeyImportFailed(let s): return "RSA 密钥导入失败: \(s)"
        case .rsaOperationFailed:        return "RSA 裸运算失败"
        case .aesFailed(let s):          return "AES 失败: \(s)"
        case .deflateFailed(let s):      return "deflate 失败: \(s)"
        case .inflateFailed(let s):      return "inflate 失败: \(s)"
        case .badResponseHeader:         return "响应头格式非法"
        case .badPadding:                return "PKCS#1 填充非法"
        }
    }
}

final class PXVRProtocol {

    // MARK: - 常量（本 APK 版本固定）

    /// 版本常量 G[16:49]。最后 4 字节为时间戳占位，发送前会被替换。
    private static let const33: [UInt8] = [
        0x7e, 0xb6, 0xe3, 0x3f, 0x14, 0xf1, 0x4b, 0x98,
        0x6c, 0xba, 0x18, 0x74, 0xf0, 0x5b, 0xdf, 0xa2,
        0x71, 0x61, 0xd8, 0x27,
        0x32, 0x30, 0x32, 0x36, 0x31, 0x30, 0x32, 0x38,   // "20261028"
        0x52,                                              // 'R'
        0x6a, 0xf3, 0x28, 0x10                            // 时间戳占位
    ]

    /// 请求方向 RSA 公钥（PKCS#1 RSAPublicKey DER，2048 位，e = 65537）
    private static let encryptPublicKeyB64 = ""   // 脱敏：公开仓库不携带密钥，需要时自行填入

    /// 响应方向 RSA 私钥（PKCS#1 RSAPrivateKey DER，含 CRT 参数）
    private static let decryptPrivateKeyB64 = ""   // 脱敏：同上

    // MARK: - DRBG 状态

    private var aesKey: [UInt8]      // 32 字节
    private var counter: [UInt8]    // 16 字节，大端
    private(set) var gIV: [UInt8] = []   // 报文 IV，init 后固定

    // MARK: - 初始化

    /// - Parameter seed: 48 字节种子。传 nil 时用 SecRandomCopyBytes 现取。
    init(seed: Data? = nil) {
        let s: [UInt8]
        if let seed = seed, seed.count == 48 {
            s = [UInt8](seed)
        } else {
            var buf = [UInt8](repeating: 0, count: 48)
            let st = SecRandomCopyBytes(kSecRandomDefault, buf.count, &buf)
            precondition(st == errSecSuccess, "SecRandomCopyBytes 失败")
            s = buf
        }
        aesKey = Array(s[0..<32])
        counter = Array(s[32..<48])

        // init: G_IV = Generate(16); Update()
        gIV = generate(16)
        update()
    }

    // MARK: - 共享实例与便捷接口

    /// 全进程共享的会话（对应 native 的 init() 只执行一次）
    static let shared = PXVRProtocol()

    /// 丢弃当前 DRBG 状态并重新播种（对应原 reset()）
    func reset() {
        var buf = [UInt8](repeating: 0, count: 48)
        let st = SecRandomCopyBytes(kSecRandomDefault, buf.count, &buf)
        precondition(st == errSecSuccess, "SecRandomCopyBytes 失败")
        aesKey = Array(buf[0..<32])
        counter = Array(buf[32..<48])
        gIV = generate(16)
        update()
    }

    /// 明文 JSON 字典 → `q=` 字段需要的 hex
    func encodeJSON(_ obj: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: []) else {
            PXVRLogger.warning("[proto] JSON 序列化失败")
            return nil
        }
        let hex = encode(data)
        return hex.isEmpty ? nil : hex
    }

    /// 响应 hex → 明文 JSON 字典
    func decodeJSON(_ hex: String) -> [String: Any]? {
        guard let bytes = Self.bytes(fromHex: hex) else {
            PXVRLogger.warning("[proto] 响应 hex 非法")
            return nil
        }
        guard let plain = try? Self.decode(Data(bytes)) else {
            PXVRLogger.warning("[proto] 响应解密失败")
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any]
    }

    // MARK: - CTR_DRBG

    private func incrementCounter() {
        var i = 15
        while i >= 0 {
            counter[i] = counter[i] &+ 1
            if counter[i] != 0 { break }
            i -= 1
        }
    }

    private func generate(_ n: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(n + 16)
        while out.count < n {
            incrementCounter()
            out += Self.aesECBEncryptBlock(key: aesKey, block: counter)
        }
        return Array(out.prefix(n))
    }

    private func update(_ data: [UInt8] = []) {
        var t: [UInt8] = []
        t.reserveCapacity(48)
        for _ in 0..<3 {
            incrementCounter()
            t += Self.aesECBEncryptBlock(key: aesKey, block: counter)
        }
        var d = [UInt8](repeating: 0, count: 48)
        for i in 0..<min(48, data.count) { d[i] = data[i] }

        aesKey = (0..<32).map { t[$0] ^ d[$0] }
        counter = (32..<48).map { t[$0] ^ d[$0] }
    }

    // MARK: - 编码（请求）

    /// 把明文编码成 `q=` 字段需要的 hex 字符串。
    /// - Parameter timestamp: 仅测试用；nil 表示取当前时间。
    func encode(_ plaintext: Data, timestamp: Int? = nil) -> String {
        let keyMaterial = generate(32)
        update()

        let payload = Self.deflateRaw([UInt8](plaintext)) + [0x01]
        let pad = (16 - payload.count % 16) % 16
        let padded = payload + [UInt8](repeating: 0, count: pad)

        let cipher = (try? Self.aesCBCEncrypt(key: keyMaterial, iv: gIV, data: padded)) ?? []
        if cipher.isEmpty { PXVRLogger.warning("[proto] AES-CBC 加密失败") }

        let digest = [UInt8](SHA256.hash(data: Data(padded)))

        var c33 = Self.const33
        let ts = UInt32(truncatingIfNeeded: timestamp ?? Int(Date().timeIntervalSince1970))
        c33[29] = UInt8((ts >> 24) & 0xff)
        c33[30] = UInt8((ts >> 16) & 0xff)
        c33[31] = UInt8((ts >> 8) & 0xff)
        c33[32] = UInt8(ts & 0xff)

        let dBlock = gIV + keyMaterial + digest + c33          // 113 字节

        // PS：140 个非零随机字节，逐字节取自 DRBG
        var ps: [UInt8] = []
        ps.reserveCapacity(140)
        while ps.count < 140 {
            let b = generate(1)[0]
            if b != 0 { ps.append(b) }
        }

        var eb: [UInt8] = [0x00, 0x02]
        eb += ps
        eb.append(0x00)
        eb += dBlock                                          // 共 256 字节

        guard let pubKey = Self.encryptPublicKey(),
              let header = try? Self.rsaRawEncrypt(eb, key: pubKey) else {
            PXVRLogger.warning("[proto] RSA 加密失败")
            return ""
        }
        return Self.hexString(header + cipher)
    }

    // MARK: - 解码（响应）

    static func decode(_ resp: Data) throws -> Data {
        let raw = [UInt8](resp)
        guard raw.count > 256 else { throw PXVRProtocolError.badResponseHeader }

        let header = Array(raw[0..<256])
        let body = Array(raw[256..<raw.count])

        guard let privKey = decryptPrivateKey() else {
            throw PXVRProtocolError.rsaKeyImportFailed("解密私钥不可用")
        }
        let block = try rsaRawDecrypt(header, key: privKey)
        guard block.count == 256, block[0] == 0x00, block[1] == 0x02 else {
            throw PXVRProtocolError.badPadding
        }
        var i = 2
        while i < block.count && block[i] != 0 { i += 1 }
        guard i < block.count else { throw PXVRProtocolError.badPadding }
        let dPrime = Array(block[(i + 1)...])
        guard dPrime.count >= 48 else { throw PXVRProtocolError.badResponseHeader }

        let iv = Array(dPrime[0..<16])
        let key = Array(dPrime[16..<48])

        let plain = try aesCBCDecrypt(key: key, iv: iv, data: body)
        // 尾部可能残留 1 字节，先按原样试，失败再去掉最后一字节
        if let out = try? inflateRaw(plain) { return out }
        if plain.count > 1, let out = try? inflateRaw(Array(plain.dropLast())) { return out }
        throw PXVRProtocolError.inflateFailed(-1)
    }

    // MARK: - AES

    private static func aesECBEncryptBlock(key: [UInt8], block: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        var outLen = 0
        let status = key.withUnsafeBytes { kp in
            block.withUnsafeBytes { bp in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        kp.baseAddress, key.count, nil,
                        bp.baseAddress, 16,
                        &out, 16, &outLen)
            }
        }
        if status != kCCSuccess { PXVRLogger.warning("[proto] AES-ECB 失败 \(status)") }
        return out
    }

    private static func aesCBCEncrypt(key: [UInt8], iv: [UInt8], data: [UInt8]) throws -> [UInt8] {
        try aesCBC(op: CCOperation(kCCEncrypt), key: key, iv: iv, data: data)
    }

    private static func aesCBCDecrypt(key: [UInt8], iv: [UInt8], data: [UInt8]) throws -> [UInt8] {
        try aesCBC(op: CCOperation(kCCDecrypt), key: key, iv: iv, data: data)
    }

    private static func aesCBC(op: CCOperation, key: [UInt8], iv: [UInt8],
                               data: [UInt8]) throws -> [UInt8] {
        guard !data.isEmpty else { return [] }
        var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var outLen = 0
        let capacity = out.count
        let status = key.withUnsafeBytes { kp in
            iv.withUnsafeBytes { ip in
                data.withUnsafeBytes { dp in
                    CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), CCOptions(0),   // 0 = CBC，无额外填充
                            kp.baseAddress, key.count, ip.baseAddress,
                            dp.baseAddress, data.count,
                            &out, capacity, &outLen)
                }
            }
        }
        guard status == kCCSuccess else { throw PXVRProtocolError.aesFailed(status) }
        return Array(out.prefix(outLen))
    }

    // MARK: - RSA（裸运算）

    private static var cachedEncryptKey: SecKey?
    private static var cachedDecryptKey: SecKey?

    private static func encryptPublicKey() -> SecKey? {
        if let k = cachedEncryptKey { return k }
        let k = makeKey(base64: encryptPublicKeyB64, isPrivate: false)
        cachedEncryptKey = k
        return k
    }

    private static func decryptPrivateKey() -> SecKey? {
        if let k = cachedDecryptKey { return k }
        let k = makeKey(base64: decryptPrivateKeyB64, isPrivate: true)
        cachedDecryptKey = k
        return k
    }

    private static func makeKey(base64: String, isPrivate: Bool) -> SecKey? {
        guard let der = Data(base64Encoded: base64) else {
            PXVRLogger.warning("[proto] RSA 密钥 base64 解码失败")
            return nil
        }
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: isPrivate ? kSecAttrKeyClassPrivate : kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 2048
        ]
        var err: Unmanaged<CFError>?
        let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &err)
        if key == nil {
            PXVRLogger.warning("[proto] SecKeyCreateWithData 失败: \(String(describing: err))")
        }
        return key
    }

    /// 裸 RSA 公钥运算（不做任何填充，填充由调用方自行构造）
    private static func rsaRawEncrypt(_ input: [UInt8], key: SecKey) throws -> [UInt8] {
        var err: Unmanaged<CFError>?
        guard let out = SecKeyCreateEncryptedData(key, .rsaEncryptionRaw,
                                                  Data(input) as CFData, &err) else {
            PXVRLogger.warning("[proto] RSA 公钥裸运算失败: \(String(describing: err))")
            throw PXVRProtocolError.rsaOperationFailed
        }
        return [UInt8](out as Data)
    }

    /// 裸 RSA 私钥运算（对应 PKCS#1 里被私钥指数作用的那一步）
    private static func rsaRawDecrypt(_ input: [UInt8], key: SecKey) throws -> [UInt8] {
        var err: Unmanaged<CFError>?
        guard let out = SecKeyCreateDecryptedData(key, .rsaEncryptionRaw,
                                                  Data(input) as CFData, &err) else {
            PXVRLogger.warning("[proto] RSA 私钥裸运算失败: \(String(describing: err))")
            throw PXVRProtocolError.rsaOperationFailed
        }
        return [UInt8](out as Data)
    }

    // MARK: - zlib

    private static func deflateRaw(_ input: [UInt8]) -> [UInt8] {
        guard !input.isEmpty else { return [] }
        var strm = z_stream()
        var status = deflateInit2_(&strm, 9, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY,
                                   ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            PXVRLogger.warning("[\(Self.self)] deflateInit2 失败 \(status)")
            return []
        }
        defer { deflateEnd(&strm) }

        let cap = input.count * 2 + 1024
        var out = [UInt8](repeating: 0, count: cap)
        input.withUnsafeBytes { raw in
            strm.next_in = UnsafeMutablePointer<Bytef>(
                mutating: raw.bindMemory(to: Bytef.self).baseAddress)
            strm.avail_in = uInt(input.count)
            out.withUnsafeMutableBytes { ob in
                strm.next_out = ob.bindMemory(to: Bytef.self).baseAddress
                strm.avail_out = uInt(cap)
                status = deflate(&strm, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else {
            PXVRLogger.warning("[proto] deflate 未正常结束 \(status)")
            return []
        }
        let produced = cap - Int(strm.avail_out)
        return Array(out[0..<produced])
    }

    private static func inflateRaw(_ input: [UInt8]) throws -> Data {
        guard !input.isEmpty else { throw PXVRProtocolError.inflateFailed(-1) }
        var strm = z_stream()
        var status = inflateInit2_(&strm, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw PXVRProtocolError.inflateFailed(status) }
        defer { inflateEnd(&strm) }

        let chunkSize = 4096
        var result = Data()
        var produced = 0
        try input.withUnsafeBytes { raw in
            strm.next_in = UnsafeMutablePointer<Bytef>(
                mutating: raw.bindMemory(to: Bytef.self).baseAddress)
            strm.avail_in = uInt(input.count)
            repeat {
                var chunk = [UInt8](repeating: 0, count: chunkSize)
                try chunk.withUnsafeMutableBytes { ob in
                    strm.next_out = ob.bindMemory(to: Bytef.self).baseAddress
                    strm.avail_out = uInt(chunkSize)
                    status = inflate(&strm, Z_NO_FLUSH)
                    produced = chunkSize - Int(strm.avail_out)
                    if status != Z_OK && status != Z_STREAM_END && status != Z_BUF_ERROR {
                        throw PXVRProtocolError.inflateFailed(status)
                    }
                }
                if produced > 0 { result.append(contentsOf: chunk[0..<produced]) }
            } while status == Z_OK && strm.avail_in > 0
        }
        guard status == Z_STREAM_END else {
            throw PXVRProtocolError.inflateFailed(status)
        }
        return result
    }

    // MARK: - 工具

    static func hexString(_ bytes: [UInt8]) -> String {
        var s = String()
        s.reserveCapacity(bytes.count * 2)
        for b in bytes { s += String(format: "%02x", b) }
        return s
    }

    static func bytes(fromHex hex: String) -> [UInt8]? {
        let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(clean.count / 2)
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2)
            guard let b = UInt8(clean[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        return out
    }
}
