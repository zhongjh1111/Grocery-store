import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        // 先挂一个空白过渡页：WKHTTPCookieStore 只能异步读，
        // 同步等待会阻塞主线程（旧实现启动时最多卡 2 秒）。
        let splash = UIViewController()
        splash.view.backgroundColor = .systemBackground
        window.rootViewController = splash
        window.makeKeyAndVisible()
        self.window = window

        CookieManager.shared.hasPixivCookie { [weak self] loggedIn in
            guard let self = self, let window = self.window else { return }
            let root: UIViewController = loggedIn ? MainViewController() : LoginViewController()
            UIView.transition(with: window, duration: 0.2, options: .transitionCrossDissolve) {
                window.rootViewController = root
            }
        }

        // 处理 URL Scheme 回调 (login.pxvr.xyz)
        if let urlContext = connectionOptions.urlContexts.first {
            handleURL(urlContext.url)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        handleURL(url)
    }

    private func handleURL(_ url: URL) {
        NotificationCenter.default.post(name: .didReceiveURL, object: url)
    }
}

extension Notification.Name {
    static let didReceiveURL = Notification.Name("didReceiveURL")
}
