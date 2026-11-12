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
