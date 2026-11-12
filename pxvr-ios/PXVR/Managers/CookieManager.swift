import Foundation
import WebKit

/// Cookie 管理器 — 对应 Android 端 CookieManager.getInstance()
/// 管理 pixiv.net 的 PHPSESSID 等认证 Cookie
class CookieManager {
    static let shared = CookieManager()

    private let cookieStore: WKHTTPCookieStore

    init() {
        let config = WKWebViewConfiguration()
        self.cookieStore = config.websiteDataStore.httpCookieStore
    }

    // MARK: - Public

    /// 检查是否已登录 (是否存在 pixiv.net 的 PHPSESSID)
    ///
    /// ⚠️ 同步版本：会阻塞调用线程最多 2 秒。WKHTTPCookieStore 只能异步读，
    /// 主线程上请改用 `hasPixivCookie(completion:)`。
    @available(*, deprecated, message: "会阻塞调用线程；主线程请用 hasPixivCookie(completion:)")
    func hasPixivCookie() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var hasCookie = false

        cookieStore.getAllCookies { cookies in
            for cookie in cookies {
                if cookie.domain.contains("pixiv.net") && cookie.name == "PHPSESSID" {
                    hasCookie = true
                    break
                }
            }
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 2)
        return hasCookie
    }

    /// 异步检查登录态，不阻塞任何线程。结果固定回主队列。
    func hasPixivCookie(completion: @escaping (Bool) -> Void) {
        cookieStore.getAllCookies { cookies in
            let has = cookies.contains { $0.domain.contains("pixiv.net") && $0.name == "PHPSESSID" }
            DispatchQueue.main.async { completion(has) }
        }
    }

    /// 获取 pixiv.net 的所有 Cookie 字符串 (格式: "key=value; key2=value2")
    func getCookies(for domain: String) -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        var cookieString: String?

        cookieStore.getAllCookies { cookies in
            let matching = cookies.filter { domain.contains($0.domain) }
            if matching.isEmpty {
                semaphore.signal()
                return
            }
            cookieString = matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 2)
        return cookieString
    }

    /// 获取 pixiv.net 的 Cookie (快捷方法)
    func getPixivCookie() -> String? {
        return getCookies(for: "pixiv.net")
    }

    /// 设置 Cookie (用于登录后注入)
    func setCookie(name: String, value: String, domain: String, path: String = "/") {
        let cookie = HTTPCookie(properties: [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
            .secure: "TRUE"
        ])!
        cookieStore.setCookie(cookie)
    }

    /// 清除所有 Cookie (退出登录)
    func clearAll() {
        let semaphore = DispatchSemaphore(value: 0)
        cookieStore.getAllCookies { cookies in
            let group = DispatchGroup()
            for cookie in cookies {
                group.enter()
                self.cookieStore.delete(cookie) {
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                semaphore.signal()
            }
        }
        _ = semaphore.wait(timeout: .now() + 3)
    }

    /// 获取共享的 WKWebViewConfiguration (带 Cookie 共享)
    static func sharedConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.websiteDataStore = WKWebsiteDataStore.default()

        // 注入 User-Agent (模拟移动端浏览器)
        config.applicationNameForUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

        return config
    }
}
