import Foundation
import UIKit

/// Pixiv API 工具 — 封装常用的 API 调用
/// 对应 Android 端 gf0.java / uh0.java 中的网络逻辑
class PixivAPI {

    static let shared = PixivAPI()

    private init() {}

    // MARK: - 解析作品 ID

    /// 从 URL 提取作品 ID
    static func extractWorkId(from url: String) -> (type: WorkType, id: String)? {
        // https://www.pixiv.net/artworks/12345678
        if url.contains("/artworks/") {
            let parts = url.components(separatedBy: "/artworks/")
            if parts.count > 1 {
                let id = parts[1].components(separatedBy: "?")[0].components(separatedBy: "#")[0]
                return (.illust, id)
            }
        }
        // https://www.pixiv.net/novel/show.php?id=12345678
        if url.contains("/novel/show.php?id=") {
            if let urlObj = URL(string: url),
               let comp = URLComponents(url: urlObj, resolvingAgainstBaseURL: false),
               let id = comp.queryItems?.first(where: { $0.name == "id" })?.value {
                return (.novel, id)
            }
        }
        // https://www.pixiv.net/novel/series/12345678
        if url.contains("/novel/series/") {
            let parts = url.components(separatedBy: "/novel/series/")
            if parts.count > 1 {
                let id = parts[1].components(separatedBy: "?")[0].components(separatedBy: "#")[0]
                return (.novelSeries, id)
            }
        }
        // https://www.pixiv.net/member.php?id=12345678
        if url.contains("/member.php?id=") {
            if let urlObj = URL(string: url),
               let comp = URLComponents(url: urlObj, resolvingAgainstBaseURL: false),
               let id = comp.queryItems?.first(where: { $0.name == "id" })?.value {
                return (.user, id)
            }
        }
        return nil
    }

    enum WorkType {
        case illust
        case novel
        case novelSeries
        case user
    }

    // MARK: - 图片 URL 构建

    /// 构建 pximg 图片 URL
    /// 对应 Android: https://i.pximg.net/img-original/img/
    static func buildImageURL(path: String) -> String {
        if path.hasPrefix("http") {
            return path
        }
        return "https://i.pximg.net/img-original/img/\(path)"
    }

    // MARK: - 下载图片 (带 Cookie)

    /// 下载图片到本地
    static func downloadImage(
        workId: String,
        imageUrl: String,
        title: String,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let cookie = CookieManager.shared.getPixivCookie()
        DownloadManager.shared.downloadImage(
            workId: workId,
            imageUrl: imageUrl,
            title: title,
            cookie: cookie,
            completion: completion
        )
    }

    // MARK: - 保存到相册

    /// 保存图片到 iOS 相册
    static func saveToPhotosAlbum(imageURL: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            do {
                let data = try Data(contentsOf: imageURL)
                if let image = UIImage(data: data) {
                    DispatchQueue.main.async {
                        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                        completion(.success(()))
                    }
                } else {
                    DispatchQueue.main.async {
                        completion(.failure(NSError(domain: "PXVR", code: -1, message: "无法解析图片")))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - 下载小说

    /// 下载小说文本
    static func downloadNovel(
        novelId: String,
        title: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let cookie = CookieManager.shared.getPixivCookie()
        DownloadManager.shared.downloadNovelText(
            novelId: novelId,
            title: title,
            cookie: cookie,
            completion: completion
        )
    }

    // MARK: - 导出小说 EPUB

    /// 下载并导出小说为 EPUB
    static func exportNovelAsEPUB(
        novelId: String,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        NetworkManager.shared.fetchNovelDetail(novelId: novelId) { result in
            switch result {
            case .success(let body):
                let title = (body["novel_details"] as? [String: Any])?["title"] as? String
                    ?? body["title"] as? String
                    ?? "Unknown"
                let author = (body["novel_details"] as? [String: Any])?["user_name"] as? String
                    ?? body["user_name"] as? String
                    ?? "Unknown"
                let text = (body["novel_details"] as? [String: Any])?["text"] as? String
                    ?? body["text"] as? String
                    ?? ""

                EPUBExporter.exportNovel(
                    novelId: novelId,
                    title: title,
                    author: author,
                    text: text,
                    completion: completion
                )

            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
}
