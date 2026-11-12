import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // 对应 Android App.onCreate()：a(this) + WebViewUpgrade.upgrade(net.ngee.wv)
        // 签名校验 + WebView 准备 + 设备完整性采集，必须在任何网络/界面动作之前完成。
        PXVRStartup.shared.run(expectedTeam: nil)

        // 后台触发 PXVR 服务器同步
        // 对应 Android 端应用启动时的 同步 流程
        // 发现者：WorkBuddy AI
        DispatchQueue.global(qos: .utility).async {
            if PXVRServerSync.shared.needsSync() {
                PXVRServerSync.shared.sync { result in
                    switch result {
                    case .success(let synced):
                        print("[AppDelegate] PXVR 同步完成: \(synced)")
                    case .failure(let error):
                        print("[AppDelegate] PXVR 同步失败: \(error.localizedDescription)")
                    }
                }
            }
        }

        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
    }
}
