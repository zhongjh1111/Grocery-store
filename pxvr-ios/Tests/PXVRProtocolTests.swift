//
//  PXVRProtocolTests.swift
//  PXVR-iOS
//
//  加密层验收测试。
//  判据：注入固定 seed + 固定 timestamp 后，encode() 的输出必须与
//        Resources/testvectors.json 里的 expected_wire_hex 逐字节一致。
//
//  向量由 Python 参考实现（pxvr_proto.py / tools/gen_vectors.py）生成，
//  该实现已通过真实服务器端到端验证。
//

import XCTest
import Security
@testable import PXVR

final class PXVRProtocolTests: XCTestCase {

    // MARK: - 向量结构

    private struct Vector: Decodable {
        let seed: String
        let timestamp: Int
        let plaintext_hex: String
        let expected_wire_hex: String
        let wire_len: Int
    }

    private struct Fixture: Decodable {
        let g_iv_hint: String
        let vectors: [Vector]
    }

    // MARK: - 载入

    private func loadFixture() throws -> Fixture {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: "testvectors", withExtension: "json") else {
            throw XCTSkip("testvectors.json 未打进测试 bundle")
        }
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }


    // MARK: - 自足验证（不依赖任何真实密钥）

    /// 临时生成一对 RSA 密钥，跑完整 encode → decode 往返。
    /// 覆盖：deflate / 零填充 / AES-256-CBC / SHA-256 / PKCS#1 / RSA 双向。
    /// 这样公开仓库里不携带任何密钥，也能验证链路是通的。
    func testEphemeralKeyRoundTrip() throws {
        let keys = try Self.makeEphemeralKeyPair()

        let payload = Data(#"{"c":"wd","v":20261028,"m":"HUAWEI ELS-AN00"}"#.utf8)
        let proto = PXVRProtocol(seed: Data(repeating: 0x5A, count: 48), keys: keys)
        let hex = proto.encode(payload, timestamp: 1_794_320_400)

        XCTAssertFalse(hex.isEmpty, "encode 返回空，说明密钥或加密链路有问题")

        guard let wire = PXVRProtocol.bytes(fromHex: hex) else {
            return XCTFail("输出不是合法 hex")
        }
        XCTAssertGreaterThan(wire.count, 256, "报文应含 256 字节头 + 密文")
        XCTAssertEqual(wire.count % 16, 0, "总长度应是 16 的倍数")

        let plain = try PXVRProtocol.decode(Data(wire), keys: keys)
        XCTAssertEqual(plain, payload, "往返后明文不一致")
    }

    /// 同一会话连续两次 encode 必须不同（DRBG 有推进）
    func testEphemeralKeyChangesPerCall() throws {
        let keys = try Self.makeEphemeralKeyPair()
        let proto = PXVRProtocol(seed: Data(repeating: 0x11, count: 48), keys: keys)
        let payload = Data(#"{"c":"wd"}"#.utf8)

        let a = proto.encode(payload, timestamp: 1_794_320_400)
        let b = proto.encode(payload, timestamp: 1_794_320_400)
        XCTAssertNotEqual(a, b, "两次 encode 应因 DRBG 推进而不同")
    }

    // MARK: - 临时密钥

    private static func makeEphemeralKeyPair() throws -> PXVRKeys {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048
        ]
        var pub: SecKey?
        var priv: SecKey?
        let status = SecKeyGeneratePair(attrs as CFDictionary, &pub, &priv)
        guard status == errSecSuccess, let pubKey = pub, let privKey = priv else {
            throw NSError(domain: "PXVRProtocolTests", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "临时密钥生成失败"])
        }
        guard let pubRef = SecKeyCopyExternalRepresentation(pubKey, nil),
              let privRef = SecKeyCopyExternalRepresentation(privKey, nil) else {
            throw NSError(domain: "PXVRProtocolTests", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "密钥导出失败"])
        }
        return PXVRKeys(encryptPublicB64: (pubRef as Data).base64EncodedString(),
                        decryptPrivateB64: (privRef as Data).base64EncodedString())
    }

    // MARK: - 用例

    /// 脱敏版仓库不携带 RSA 密钥；此时跳过所有依赖真实密钥的用例。
    private func requireKeys() throws {
        let probe = PXVRProtocol(seed: Data(repeating: 1, count: 48))
            .encode(Data("{}".utf8), timestamp: 0)
        if probe.isEmpty {
            throw XCTSkip("未配置 RSA 密钥（脱敏版仓库），跳过需要密钥的用例")
        }
    }


    /// 核心验收：6 组向量逐字节比对
    func testEncodeMatchesReferenceVectors() throws {
        try requireKeys()
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.vectors.isEmpty, "向量为空")

        for (i, v) in fixture.vectors.enumerated() {
            guard let seedBytes = PXVRProtocol.bytes(fromHex: v.seed) else {
                XCTFail("#\(i) seed hex 解析失败: \(v.seed)")
                continue
            }
            XCTAssertEqual(seedBytes.count, 48, "#\(i) seed 长度应为 48")

            guard let plainBytes = PXVRProtocol.bytes(fromHex: v.plaintext_hex) else {
                XCTFail("#\(i) 明文 hex 解析失败")
                continue
            }

            let proto = PXVRProtocol(seed: Data(seedBytes))
            let got = proto.encode(Data(plainBytes), timestamp: v.timestamp)

            XCTAssertFalse(got.isEmpty, "#\(i) encode 返回空")
            XCTAssertEqual(got.count, v.wire_len * 2, "#\(i) 长度不符")
            XCTAssertEqual(got, v.expected_wire_hex, "#\(i) 密文不一致")
        }
    }

    /// DRBG 播种后首个 16 字节（即报文 IV）应与参考实现一致
    func testGIVMatchesReference() throws {
        try requireKeys()
        let fixture = try loadFixture()
        guard let first = fixture.vectors.first,
              let seedBytes = PXVRProtocol.bytes(fromHex: first.seed) else {
            throw XCTSkip("无向量")
        }
        let proto = PXVRProtocol(seed: Data(seedBytes))
        XCTAssertEqual(PXVRProtocol.hexString(proto.gIV), fixture.g_iv_hint,
                       "G_IV 与参考实现不一致，说明 DRBG 实现有偏差")
    }

    /// 同 seed 同 timestamp 必须完全可复现
    func testDeterministic() throws {
        try requireKeys()
        let fixture = try loadFixture()
        guard let first = fixture.vectors.first,
              let seedBytes = PXVRProtocol.bytes(fromHex: first.seed),
              let plainBytes = PXVRProtocol.bytes(fromHex: first.plaintext_hex) else {
            throw XCTSkip("无向量")
        }
        let a = PXVRProtocol(seed: Data(seedBytes)).encode(Data(plainBytes), timestamp: first.timestamp)
        let b = PXVRProtocol(seed: Data(seedBytes)).encode(Data(plainBytes), timestamp: first.timestamp)
        XCTAssertEqual(a, b, "两次 encode 结果不一致")
    }

    /// hex 工具往返
    func testHexRoundTrip() {
        let bytes: [UInt8] = [0x00, 0x0f, 0xa5, 0xff]
        XCTAssertEqual(PXVRProtocol.hexString(bytes), "000fa5ff")
        XCTAssertEqual(PXVRProtocol.bytes(fromHex: "000fa5ff"), bytes)
        XCTAssertNil(PXVRProtocol.bytes(fromHex: "0g"))
        XCTAssertNil(PXVRProtocol.bytes(fromHex: "abc"))
    }
}
