# pxvr-ios

一个用 Swift 重写的 iOS 客户端工程，纯个人学习/自用。

> 放在独立子目录里，是因为仓库根目录还要放别的东西，不想互相干扰。

## 目录

```
pxvr-ios/
├── PXVR/                      应用源码
│   ├── App/                   入口、Scene、Info.plist
│   ├── Managers/              网络、Cookie、下载、数据
│   ├── Models/                数据模型
│   ├── Utils/                 协议实现、播放器、导出
│   └── Views/                 界面
├── Tests/                     单元测试
├── project.yml                XcodeGen 工程定义（.xcodeproj 由它生成，不入库）
└── PXVR-iOS-Bridging-Header.h zlib 桥接
```

## 构建

需要 macOS + Xcode。

```bash
brew install xcodegen
cd pxvr-ios
xcodegen generate
open PXVR.xcodeproj
```

## 关于配置

本仓库是**脱敏版本**：`PXVRConfig.swift` 和 `PXVRBootstrap.swift` 里的服务器地址、
签名指纹、密钥等常量已经替换成占位符（`example.com`、全 0、`PLACEHOLDER_SALT`）。

想真正跑起来，需要自己把这些值填回去；否则：

- 网络请求会打到 `example.com`，必然失败
- `PXVRProtocol.encode()` 因为密钥为空会直接返回空串
- 单元测试里的 `requireKeys()` 会跳过所有需要密钥的用例

## 测试

`Tests/PXVRProtocolTests.swift` 里有四组用例：

| 用例 | 作用 |
|---|---|
| `testEncodeMatchesReferenceVectors` | 用固定种子和固定时间戳，逐字节比对密文 |
| `testGIVMatchesReference` | 校验随机数发生器的初始状态 |
| `testDeterministic` | 同输入必须同输出 |
| `testHexRoundTrip` | 十六进制工具函数 |

后三组不需要密钥，随时可跑；第一组需要向量文件和密钥，脱敏版里会跳过。

## CI

`.github/workflows/ios.yml` 会在 `pxvr-ios/` 有改动时自动构建并跑测试。
因为是脱敏版，CI 实际只能验证**能否编译**，验证不了加密逻辑的正确性。

## 说明

仅用于个人学习和研究，不保证任何可用性。工程里第三方库的接口、协议细节
均来自公开资料与个人分析，请勿用于商业用途。
