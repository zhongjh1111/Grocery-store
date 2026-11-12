import UIKit
import WebKit

/// 主界面 — 对应 Android 端 MainActivity
/// 核心是一个 WKWebView 浏览 pixiv.net，拦截 touch/ajax 请求做本地处理
class MainViewController: UIViewController {

    private var webView: WKWebView!
    private var bottomBar: UITabBar!
    private var progressView: UIProgressView!
    private var navigationBar: UINavigationBar!

    // 页面类型
    private enum Tab: Int, CaseIterable {
        case home = 0
        case bookmarks = 1
        case history = 2
        case downloads = 3
        case settings = 4

        var title: String {
            switch self {
            case .home: return "首页"
            case .bookmarks: return "书签"
            case .history: return "历史"
            case .downloads: return "下载"
            case .settings: return "设置"
            }
        }

        var icon: String {
            switch self {
            case .home: return "house"
            case .bookmarks: return "bookmark"
            case .history: return "clock"
            case .downloads: return "arrow.down.circle"
            case .settings: return "gearshape"
            }
        }
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadPixivHome()

        // 监听 URL Scheme 回调
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleURL(_:)),
            name: .didReceiveURL, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - UI Setup

    private func setupUI() {
        view.backgroundColor = .systemBackground

        // Navigation Bar
        navigationBar = UINavigationBar()
        navigationBar.translatesAutoresizingMaskIntoConstraints = false
        let navItem = UINavigationItem(title: "PXVR")
        navItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "chevron.left"),
            style: .plain, target: self, action: #selector(goBack)
        )
        navItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "plus.circle"),
            style: .plain, target: self, action: #selector(addBookmark)
        )
        navItem.leftBarButtonItem?.isEnabled = false
        navigationBar.items = [navItem]
        view.addSubview(navigationBar)

        // WebView
        let config = CookieManager.sharedConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.addObserver(self, forKeyPath: "canGoBack", options: .new, context: nil)
        webView.addObserver(self, forKeyPath: "estimatedProgress", options: .new, context: nil)
        view.addSubview(webView)

        // Progress
        progressView = UIProgressView(progressViewStyle: .bar)
        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.progressTintColor = .systemRed
        view.addSubview(progressView)

        // Bottom Tab Bar
        bottomBar = UITabBar()
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.delegate = self
        bottomBar.items = Tab.allCases.map { tab in
            UITabBarItem(title: tab.title, image: UIImage(systemName: tab.icon), tag: tab.rawValue)
        }
        bottomBar.selectedItem = bottomBar.items?.first
        view.addSubview(bottomBar)

        // Layout
        NSLayoutConstraint.activate([
            navigationBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            navigationBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            navigationBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            progressView.topAnchor.constraint(equalTo: navigationBar.bottomAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 3),

            webView.topAnchor.constraint(equalTo: progressView.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    // MARK: - Navigation

    private func loadPixivHome() {
        let url = URL(string: "https://www.pixiv.net/")!
        webView.load(URLRequest(url: url))
    }

    @objc private func goBack() {
        if webView.canGoBack {
            webView.goBack()
        }
    }

    @objc private func addBookmark() {
        guard let url = webView.url?.absoluteString,
              let title = webView.title else { return }

        let bookmark = Bookmark(title: title, url: url)
        DataManager.shared.addBookmark(bookmark)

        let alert = UIAlertController(title: "已添加书签", message: title, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好的", style: .default))
        present(alert, animated: true)
    }

    @objc private func handleURL(_ notification: Notification) {
        guard let url = notification.object as? URL else { return }

        // 处理 login.pxvr.xyz 回调
        if url.host == "login.pxvr.xyz" {
            let m = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "m" })?.value
            let p = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "p" })?.value

            if let m = m, let p = p {
                // 自动登录 pixiv.net
                autoLogin(email: m, password: p)
            }
        }
    }

    /// 自动登录 pixiv.net (通过 WebView 提交表单)
    private func autoLogin(email: String, password: String) {
        let loginScript = """
        (function() {
            var emailInput = document.querySelector('input[name="pixiv_id"], input[type="email"], input[name="email"]');
            var passInput = document.querySelector('input[name="password"], input[type="password"]');
            var form = document.querySelector('form#login-form, form[action*="login"]');

            if (emailInput && passInput) {
                emailInput.value = '\(email)';
                passInput.value = '\(password)';
                if (form) {
                    form.submit();
                } else if (typeof login !== 'undefined') {
                    login();
                }
            }
        })();
        """

        // 先加载 pixiv 登录页
        let loginURL = URL(string: "https://accounts.pixiv.net/login")!
        webView.load(URLRequest(url: loginURL))

        // 页面加载完成后注入登录脚本
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.webView.evaluateJavaScript(loginScript) { _, _ in
                // 等待登录完成后跳转首页
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self?.loadPixivHome()
                }
            }
        }
    }

    // MARK: - KVO

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "canGoBack" {
            navigationBar.topItem?.leftBarButtonItem?.isEnabled = webView.canGoBack
        } else if keyPath == "estimatedProgress" {
            let progress = Float(webView.estimatedProgress)
            progressView.setProgress(progress, animated: true)
            if progress >= 1.0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.progressView.setProgress(0, animated: false)
                }
            }
        }
    }
}

// MARK: - WKNavigationDelegate

extension MainViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let urlString = url.absoluteString

        // 拦截 pixiv.net touch/ajax 请求 — 可以在这里做缓存/预处理
        if urlString.contains("pixiv.net") && (urlString.contains("/touch/ajax/") || urlString.contains("/ajax/")) {
            // 允许请求通过，但记录到历史
            if let title = webView.title, !title.isEmpty {
                let history = HistoryItem(title: title, url: urlString)
                DataManager.shared.addHistory(history)
            }
            decisionHandler(.allow)
            return
        }

        // 外部链接用系统浏览器打开
        if !urlString.contains("pixiv.net") && !urlString.contains("pximg.net") && !urlString.contains("pxvr.xyz") {
            if navigationAction.navigationType == .linkActivated {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 注入 CSS 优化移动端显示
        let cssInjection = """
        (function() {
            var style = document.createElement('style');
            style.textContent = `
                body { -webkit-touch-callout: none; }
                img { -webkit-user-select: none; }
            `;
            document.head.appendChild(style);
        })();
        """
        webView.evaluateJavaScript(cssInjection)

        // 记录浏览历史
        if let url = webView.url?.absoluteString, let title = webView.title {
            let history = HistoryItem(title: title, url: url)
            DataManager.shared.addHistory(history)
        }
    }
}

// MARK: - WKUIDelegate

extension MainViewController: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // 新窗口在当前 WebView 打开
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}

// MARK: - UITabBarDelegate

extension MainViewController: UITabBarDelegate {
    func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        guard let tab = Tab(rawValue: item.tag) else { return }

        switch tab {
        case .home:
            loadPixivHome()

        case .bookmarks:
            let vc = BookmarkViewController()
            vc.onSelectBookmark = { [weak self] bookmark in
                self?.webView.load(URLRequest(url: URL(string: bookmark.url)!))
            }
            let nav = UINavigationController(rootViewController: vc)
            present(nav, animated: true)

        case .history:
            let vc = HistoryViewController()
            vc.onSelectHistory = { [weak self] history in
                self?.webView.load(URLRequest(url: URL(string: history.url)!))
            }
            let nav = UINavigationController(rootViewController: vc)
            present(nav, animated: true)

        case .downloads:
            let vc = DownloadListViewController()
            let nav = UINavigationController(rootViewController: vc)
            present(nav, animated: true)

        case .settings:
            let vc = SettingsViewController()
            let nav = UINavigationController(rootViewController: vc)
            present(nav, animated: true)
        }

        // 重新选中首页
        DispatchQueue.main.async {
            tabBar.selectedItem = tabBar.items?.first
        }
    }
}
