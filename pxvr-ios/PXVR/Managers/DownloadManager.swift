import Foundation

/// 下载管理器 — 对应 Android 端 DownloaderActivity + Download 对象
class DownloadManager {
    static let shared = DownloadManager()

    private let session: URLSession
    private var activeTasks: [UUID: URLSessionDownloadTask] = [:]

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 0 // 不超时
        self.session = URLSession(configuration: config)
    }

    /// 下载图片
    func downloadImage(
        workId: String,
        imageUrl: String,
        title: String,
        cookie: String?,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard let url = URL(string: imageUrl) else {
            completion(.failure(NSError(domain: "PXVR", code: -1, message: "Invalid URL")))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("https://www.pixiv.net/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        if let cookie = cookie {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        // 创建下载记录
        var downloadItem = DownloadItem(workId: workId, url: imageUrl, title: title, type: .original)
        downloadItem.cookieInfo = cookie
        DataManager.shared.addDownload(downloadItem)

        let task = session.downloadTask(with: request) { tempURL, response, error in
            if let error = error {
                downloadItem.status = .failed
                DataManager.shared.updateDownload(downloadItem)
                completion(.failure(error))
                return
            }

            guard let tempURL = tempURL else {
                downloadItem.status = .failed
                DataManager.shared.updateDownload(downloadItem)
                completion(.failure(NSError(domain: "PXVR", code: -2, message: "No file")))
                return
            }

            // 保存到 Documents/PXVR/Downloads/
            let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let downloadDir = docsDir.appendingPathComponent("PXVR/Downloads", isDirectory: true)
            try? FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)

            let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
            let filename = "\(workId)_\(UUID().uuidString.prefix(8)).\(ext)"
            let destURL = downloadDir.appendingPathComponent(filename)

            do {
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: destURL)

                downloadItem.filePath = destURL.path
                downloadItem.status = .done
                if let response = response as? HTTPURLResponse,
                   let length = response.expectedContentLength as Int64?, length > 0 {
                    downloadItem.totalSize = length
                    downloadItem.finishedSize = length
                }
                DataManager.shared.updateDownload(downloadItem)

                completion(.success(destURL))
            } catch {
                downloadItem.status = .failed
                DataManager.shared.updateDownload(downloadItem)
                completion(.failure(error))
            }
        }

        activeTasks[downloadItem.id] = task
        task.resume()
    }

    /// 下载小说文本
    func downloadNovelText(
        novelId: String,
        title: String,
        cookie: String?,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        NetworkManager.shared.fetchNovelDetail(novelId: novelId) { result in
            switch result {
            case .success(let body):
                let text = (body["novel_details"] as? [String: Any])?["text"] as? String
                    ?? body["text"] as? String
                    ?? ""
                let novelText = """
                \(title)

                \(text)

                ---
                来源: https://www.pixiv.net/novel/show.php?id=\(novelId)
                导出时间: \(Date())
                发现者: WorkBuddy AI
                """

                // 保存到文件
                let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let downloadDir = docsDir.appendingPathComponent("PXVR/Novels", isDirectory: true)
                try? FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)
                let fileURL = downloadDir.appendingPathComponent("\(novelId)_\(title).txt")
                try? novelText.data(using: .utf8)?.write(to: fileURL)

                // 记录下载
                var downloadItem = DownloadItem(workId: novelId, url: "https://www.pixiv.net/novel/show.php?id=\(novelId)", title: title, type: .novel)
                downloadItem.filePath = fileURL.path
                downloadItem.status = .done
                DataManager.shared.addDownload(downloadItem)

                completion(.success(novelText))

            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
}
