//
//  PXVRConfig.swift
//  PXVR-iOS
//
//  共享常量、日志、配置签名校验。
//  关键点：configSalt / p12Password 是「互锁常量」——同时用于 config/.json 签名盐、
//  PKCS#12 证书密码、KDF 相关盐。必须与 Android / Windows 版本逐字节一致，禁止改动。
//

import Foundation
import os
import CryptoKit

// MARK: - 日志

enum PXVRLogger {
    private static let log = OSLog(subsystem: "net.ngee.pxvr", category: "pxvr")

    /// 额外日志出口。UI 壳用它把网络层日志汇到屏幕上的日志面板。
    /// 可能在任意线程被调用，实现方自行切主线程。
    static var sink: ((String) -> Void)?

    static func info(_ s: String) {
        os_log("%{public}@", log: log, type: .info, s)
        sink?("[net] " + s)
    }
    static func warning(_ s: String) {
        os_log("%{public}@", log: log, type: .error, s)
        sink?("[net] " + s)
    }
    static func debug(_ s: String) {
        os_log("%{public}@", log: log, type: .debug, s)
        sink?("[net] " + s)
    }
}

// MARK: - 注入的私有常量

/// 从 Bundle 的 `PXVRKeys.json` 读取私有常量（CI 用 Actions Secret 注入）。
/// 公开仓库里不含真值，读不到就退回占位串——此时握手必然失败，属于预期行为。
enum PXVRInjected {
    static let values: [String: String] = {
        guard let url = Bundle.main.url(forResource: "PXVRKeys", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
        else { return [:] }
        return obj
    }()

    static func string(_ key: String) -> String? {
        guard let v = values[key], !v.isEmpty else { return nil }
        return v
    }
}

// MARK: - 常量（互锁，禁止改动）

enum PXVRConstants {
    /// 配置签名盐 / PKCS#12 密码 / KDF 盐 —— 同一常量，互锁。
    /// 真值通过 Secret 注入；仓库里是占位串。
    static var configSalt: String { PXVRInjected.string("configSalt") ?? "PLACEHOLDER_SALT" }
    static var p12Password: String { PXVRInjected.string("configSalt") ?? "PLACEHOLDER_SALT" }
    static let p12Name     = "pxvr"          // Bundle 内 pxvr.p12
    static let p12Alias    = "exampleWEB"    // PKCS#12 内别名（mTLS 客户端证书）

    /// 应用版本号（对应 Android BuildConfig.VERSION_CODE / v 字段）。
    /// 取当前 APK 版本 20261028；与 CONST33 里的版本串、/xc 上报的 v 必须一致。
    static let appVersion: Int = 20261028

    /// 接口路径（与 Android 一致，服务端锁死）。
    static let pathDeviceKey  = "/xk"   // 拿设备 key（空 JSON）
    static let pathDeviceAuth = "/xc"   // 设备认证 + 上报

    /// 服务器下发的 config 文件名：Android 端 = SHA256(各签名哈希拼接 + 包名 + salt)，按 app 签名隔离。
    /// 离线无法计算（没有官方签名/包名），故留空。上线前从真机/抓包取得真实 configName 填入；
    /// 为空时 fetchServerConfig 跳过（不影响 /xk+/xc 握手，但拿不到官方 UA/rd/tru 等下发配置）。
    static let configName: String? = nil

    /// 服务地址（脱敏版仓库已置空，请填入自己的配置）。
    /// 主端点 `c.example.com`（带 `!` 标记 = 默认 443）；Android 在 `Android 端` 里遍历该列表、首选 `!` 主机。
    /// 其它备份端点：`example.com` / `d.pxvr.xyz` / `dl.ngee.net` / `pxvr.s3-accelerate.amazonaws.com`。
    static let serverBaseURL = URL(string: "https://c.example.com")!
}

// MARK: - 设备画像（伪装成真实 Android 客户端，避免服务器起疑）

/// 服务器能观测到的「设备侧」字段。原 Android 上报 MANUFACTURER+MODEL / SDK_INT / WebView 版本 / 应用版本。
/// 策略（用户拍板）：先不伪装——默认发真实 iOS 值，用真机发一个包看服务器是否查；若查再开 `spoofAndroid`。
struct PXVRDeviceProfile {
    static let shared = PXVRDeviceProfile()

    /// 是否伪装成 Android。默认 false：先发真实 iOS 值做实证测试；若服务器起疑再设 true。
    var spoofAndroid: Bool = false

    // —— Android 伪装值（仅 spoofAndroid = true 时使用）——
    private var androidManufacturer: String = "samsung"
    private var androidModel: String = "SM-G973F"
    private var androidSdkInt: Int = 33

    // —— iOS 真实值 ——
    private static func iosMachine() -> String {
        var sysInfo = utsname(); uname(&sysInfo)
        let mirror = Mirror(reflecting: sysInfo.machine)
        return mirror.children.reduce("") { acc, el in
            guard let v = el.value as? Int8, v != 0 else { return acc }
            return acc + String(UnicodeScalar(UInt8(bitPattern: v)))
        }
    }
    /// m：spoof 时用 Android 的 `MANUFACTURER + " " + MODEL`（注意中间有空格，对应 `Android 端` 的 `Build.MANUFACTURER + ' ' + Build.MODEL`）；否则 iOS machine 串
    var deviceString: String {
        spoofAndroid ? (androidManufacturer + " " + androidModel) : Self.iosMachine()
    }
    /// s：spoof 时用 Android SDK_INT；否则 iOS 主版本号
    var sdkInt: Int {
        spoofAndroid ? androidSdkInt : ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }
    /// wv：对应 Android 侧 `net.ngee.wv` 伴生 APK 的 versionName。
    /// iOS 上根本不存在该伴生 APK，因此与「未安装该伴生 APK 的 Android 设备」完全一致 —— 固定为空串 ""。
    /// 这是最忠实也最不易起疑的取值（官方在未安装 companion 时即下发 ""；且 `/xc` 的 `wv` 不在加密体里、只是上报字段）。
    var webViewVersion: String { "" }
    /// v：应用版本（与设备无关，保持 APK 上报值 20260606，避免服务器按版本拒绝）
    var appVersion: Int = PXVRConstants.appVersion
}

// MARK: - 请求画像（HTTP 头伪装）

/// 服务器在传输层之外能看到的 HTTP 头。UA 与任何签名/自定义头必须和真·Android 客户端一致，
/// 否则按 UA 分流、风控或签名校验会发现非官方客户端。
struct PXVRRequestProfile {
    /// User-Agent：替换为真实 Android 客户端抓包得到的值（mitmproxy / Charles）。
    static var userAgent: String = "PixivAndroidApp/6.9.0 (Android 13; SM-G973F)"
    /// 其他需要伪装的请求头（如 X-Requested-With、签名头、设备头）。从真实 Android 抓包填充。
    static var extraHeaders: [String: String] = [:]
}

// MARK: - 配置签名校验

struct PXVRConfig {

    /// 校验服务器下发的 config 签名：sig = SHA512(configSalt + body) 的前 N 字节。
    /// 与 Android 的 config/.json 签名逻辑一致，salt 为 PXVRConstants.configSalt。
    static func verify(body: Data, signature: Data) -> Bool {
        guard let salt = PXVRConstants.configSalt.data(using: .utf8) else { return false }
        let salted = salt + body
        let expected = Data(SHA512.hash(data: salted))
        guard expected.count >= signature.count else { return false }
        return expected.prefix(signature.count) == signature
    }

    /// 计算配置签名（本地生成 config 时用于自检）。
    static func signature(of body: Data) -> Data {
        guard let salt = PXVRConstants.configSalt.data(using: .utf8) else { return Data() }
        return Data(SHA512.hash(data: salt + body))
    }
}
