import UIKit
import WebKit

/// 登录界面 — 对应 Android 端 LoginActivity
/// 1. 用户输入 Pixiv 邮箱+密码
/// 2. 通过 WebView 登录 pixiv.net
/// 3. 登录成功后 Cookie 自动保存，跳转主界面
class LoginViewController: UIViewController {

    private var webView: WKWebView!
    private var emailField: UITextField!
    private var passwordField: UITextField!
    private var loginButton: UIButton!
    private var registerButton: UIButton!
    private var infoLabel: UILabel!
    private var loadingIndicator: UIActivityIndicatorView!

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()

        // 监听 URL Scheme 回调 (login.pxvr.xyz)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleURL(_:)),
            name: .didReceiveURL, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - UI

    private func setupUI() {
        view.backgroundColor = .systemBackground

        // Logo
        let logoLabel = UILabel()
        logoLabel.text = "PXVR"
        logoLabel.font = UIFont.systemFont(ofSize: 42, weight: .bold)
        logoLabel.textColor = .systemRed
        logoLabel.textAlignment = .center
        logoLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(logoLabel)

        let subtitleLabel = UILabel()
        subtitleLabel.text = "Pixiv 第三方客户端"
        subtitleLabel.font = UIFont.systemFont(ofSize: 14)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.textAlignment = .center
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(subtitleLabel)

        // Email
        emailField = UITextField()
        emailField.placeholder = "Pixiv ID / 邮箱"
        emailField.borderStyle = .roundedRect
        emailField.keyboardType = .emailAddress
        emailField.autocapitalizationType = .none
        emailField.autocorrectionType = .no
        emailField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emailField)

        // Password
        passwordField = UITextField()
        passwordField.placeholder = "密码"
        passwordField.borderStyle = .roundedRect
        passwordField.isSecureTextEntry = true
        passwordField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(passwordField)

        // Login Button
        loginButton = UIButton(type: .system)
        loginButton.setTitle("登录", for: .normal)
        loginButton.backgroundColor = .systemRed
        loginButton.setTitleColor(.white, for: .normal)
        loginButton.layer.cornerRadius = 10
        loginButton.translatesAutoresizingMaskIntoConstraints = false
        loginButton.addTarget(self, action: #selector(loginTapped), for: .touchUpInside)
        view.addSubview(loginButton)

        // Register Button
        registerButton = UIButton(type: .system)
        registerButton.setTitle("注册 Pixiv 账号", for: .normal)
        registerButton.translatesAutoresizingMaskIntoConstraints = false
        registerButton.addTarget(self, action: #selector(registerTapped), for: .touchUpInside)
        view.addSubview(registerButton)

        // Info
        infoLabel = UILabel()
        infoLabel.text = "登录后 Cookie 将保存在本地，用于访问 Pixiv 内容"
        infoLabel.font = UIFont.systemFont(ofSize: 12)
        infoLabel.textColor = .tertiaryLabel
        infoLabel.numberOfLines = 0
        infoLabel.textAlignment = .center
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(infoLabel)

        // Loading
        loadingIndicator = UIActivityIndicatorView(style: .large)
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.isHidden = true
        view.addSubview(loadingIndicator)

        // Layout
        let padding: CGFloat = 32

        NSLayoutConstraint.activate([
            logoLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60),
            logoLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            subtitleLabel.topAnchor.constraint(equalTo: logoLabel.bottomAnchor, constant: 8),
            subtitleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            emailField.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 50),
            emailField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: padding),
            emailField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -padding),
            emailField.heightAnchor.constraint(equalToConstant: 48),

            passwordField.topAnchor.constraint(equalTo: emailField.bottomAnchor, constant: 16),
            passwordField.leadingAnchor.constraint(equalTo: emailField.leadingAnchor),
            passwordField.trailingAnchor.constraint(equalTo: emailField.trailingAnchor),
            passwordField.heightAnchor.constraint(equalToConstant: 48),

            loginButton.topAnchor.constraint(equalTo: passwordField.bottomAnchor, constant: 24),
            loginButton.leadingAnchor.constraint(equalTo: emailField.leadingAnchor),
            loginButton.trailingAnchor.constraint(equalTo: emailField.trailingAnchor),
            loginButton.heightAnchor.constraint(equalToConstant: 48),

            registerButton.topAnchor.constraint(equalTo: loginButton.bottomAnchor, constant: 16),
            registerButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            infoLabel.topAnchor.constraint(equalTo: registerButton.bottomAnchor, constant: 30),
            infoLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: padding),
            infoLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -padding),

            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    // MARK: - Actions

    @objc private func loginTapped() {
        guard let email = emailField.text, !email.isEmpty,
              let password = passwordField.text, !password.isEmpty else {
            showAlert(title: "提示", message: "请输入邮箱和密码")
            return
        }

        loadingIndicator.isHidden = false
        loadingIndicator.startAnimating()
        loginButton.isEnabled = false

        // 用 WebView 登录 pixiv.net
        performWebViewLogin(email: email, password: password)
    }

    @objc private func registerTapped() {
        if let url = URL(string: "https://accounts.pixiv.net/signup") {
            UIApplication.shared.open(url)
        }
    }

    @objc private func handleURL(_ notification: Notification) {
        guard let url = notification.object as? URL else { return }

        if url.host == "login.pxvr.xyz" {
            let m = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "m" })?.value
            let p = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "p" })?.value

            if let m = m, let p = p {
                emailField.text = m
                passwordField.text = p
                performWebViewLogin(email: m, password: p)
            }
        }
    }

    // MARK: - WebView Login

    private func performWebViewLogin(email: String, password: String) {
        // 创建隐藏 WebView 加载 pixiv 登录页
        let config = CookieManager.sharedConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self

        let loginURL = URL(string: "https://accounts.pixiv.net/login?lang=zh")!
        webView.load(URLRequest(url: loginURL))

        // 3秒后注入登录脚本
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.injectLoginScript(email: email, password: password)
        }
    }

    private func injectLoginScript(email: String, password: String) {
        let script = """
        (function() {
            var emailInput = document.querySelector('input[name="pixiv_id"], input[type="email"], input[name="email"]');
            var passInput = document.querySelector('input[name="password"], input[type="password"]');
            var form = document.querySelector('form#login-form, form[action*="login"]');

            if (emailInput && passInput) {
                emailInput.value = '\(email)';
                passInput.value = '\(password)';

                // 尝试触发 React 事件
                var nativeInputValueSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
                nativeInputValueSetter.call(emailInput, '\(email)');
                nativeInputValueSetter.call(passInput, '\(password)');
                emailInput.dispatchEvent(new Event('input', { bubbles: true }));
                passInput.dispatchEvent(new Event('input', { bubbles: true }));

                if (form) {
                    form.submit();
                    return 'submitted';
                }
            }
            return 'failed';
        })();
        """

        webView.evaluateJavaScript(script) { [weak self] result, error in
            if let error = error {
                print("Login script error: \(error)")
            }

            // 等待登录完成后检查 Cookie
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self?.checkLoginStatus()
            }
        }
    }

    private func checkLoginStatus() {
        // 检查是否获得了 pixiv.net 的 PHPSESSID
        DispatchQueue.global().async {
            let hasCookie = CookieManager.shared.hasPixivCookie()

            DispatchQueue.main.async {
                self.loadingIndicator.stopAnimating()
                self.loadingIndicator.isHidden = true
                self.loginButton.isEnabled = true

                if hasCookie {
                    self.loginSuccess()
                } else {
                    self.showAlert(title: "登录失败", message: "请检查邮箱和密码是否正确")
                }
            }
        }
    }

    private func loginSuccess() {
        let alert = UIAlertController(title: "登录成功", message: "欢迎回来！", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "进入", style: .default) { _ in
            self.transitionToMain()
        })
        present(alert, animated: true)
    }

    private func transitionToMain() {
        guard let scene = view.window?.windowScene,
              let windowDelegate = scene.delegate as? SceneDelegate else { return }
        windowDelegate.window?.rootViewController = MainViewController()
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好的", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - WKNavigationDelegate

extension LoginViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 检查是否已经登录成功 (URL 跳转到 pixiv.net 主页)
        if let url = webView.url?.absoluteString,
           url.contains("www.pixiv.net") && !url.contains("accounts.pixiv.net") {
            checkLoginStatus()
        }
    }
}
