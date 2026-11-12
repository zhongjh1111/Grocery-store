import Foundation

/// 本地数据管理器 — 对应 Android 端 ObjectBox 数据库
/// 使用 JSON 文件持久化 (简单可靠，无需 CoreData)
class DataManager {
    static let shared = DataManager()

    private let fileManager = FileManager.default
    private let docsDir: URL

    private init() {
        docsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PXVR", isDirectory: true)
        try? fileManager.createDirectory(at: docsDir, withIntermediateDirectories: true)
    }

    // MARK: - Bookmarks

    func loadBookmarks() -> [Bookmark] {
        return load(Bookmark.self, filename: "bookmarks.json") ?? []
    }

    func saveBookmarks(_ bookmarks: [Bookmark]) {
        save(bookmarks, filename: "bookmarks.json")
    }

    func addBookmark(_ bookmark: Bookmark) {
        var bookmarks = loadBookmarks()
        // 去重
        bookmarks.removeAll { $0.url == bookmark.url }
        bookmarks.insert(bookmark, at: 0)
        saveBookmarks(bookmarks)
    }

    func removeBookmark(url: String) {
        var bookmarks = loadBookmarks()
        bookmarks.removeAll { $0.url == url }
        saveBookmarks(bookmarks)
    }

    func isBookmarked(url: String) -> Bool {
        return loadBookmarks().contains { $0.url == url }
    }

    // MARK: - History

    func loadHistory() -> [HistoryItem] {
        return load(HistoryItem.self, filename: "history.json") ?? []
    }

    func saveHistory(_ history: [HistoryItem]) {
        save(history, filename: "history.json")
    }

    func addHistory(_ item: HistoryItem) {
        var history = loadHistory()
        // 去重，移到最前
        history.removeAll { $0.url == item.url }
        history.insert(item, at: 0)
        // 限制最多 500 条
        if history.count > 500 {
            history = Array(history.prefix(500))
        }
        saveHistory(history)
    }

    func clearHistory() {
        saveHistory([])
    }

    // MARK: - Downloads

    func loadDownloads() -> [DownloadItem] {
        return load(DownloadItem.self, filename: "downloads.json") ?? []
    }

    func saveDownloads(_ downloads: [DownloadItem]) {
        save(downloads, filename: "downloads.json")
    }

    func addDownload(_ item: DownloadItem) {
        var downloads = loadDownloads()
        downloads.insert(item, at: 0)
        saveDownloads(downloads)
    }

    func updateDownload(_ item: DownloadItem) {
        var downloads = loadDownloads()
        if let index = downloads.firstIndex(where: { $0.id == item.id }) {
            downloads[index] = item
            saveDownloads(downloads)
        }
    }

    func removeDownload(id: UUID) {
        var downloads = loadDownloads()
        downloads.removeAll { $0.id == id }
        saveDownloads(downloads)
    }

    // MARK: - Settings

    func getSetting<T>(_ key: String, defaultValue: T) -> T {
        let url = docsDir.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = dict[key] as? T else {
            return defaultValue
        }
        return value
    }

    func setSetting<T>(_ key: String, value: T) {
        let url = docsDir.appendingPathComponent("settings.json")
        var dict: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = existing
        }
        dict[key] = value
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted) {
            try? data.write(to: url)
        }
    }

    // MARK: - Usage Stats

    /// 获取使用统计数据
    /// 对应 Android ro0.c(JSONObject) 中的网络统计上报
    /// 发现者：WorkBuddy AI
    func getUsageStats() -> String {
        let bookmarks = loadBookmarks().count
        let history = loadHistory().count
        let downloads = loadDownloads().count

        // 格式: "type|count|rate|time|speed"
        // 对应 Android: str + '|' + substring2 + '|' + i2 + '|' + i8 + '|' + i3
        return "bm|\(bookmarks)|100|0|0;dl|\(downloads)|100|0|0;hi|\(history)|100|0|0"
    }

    // MARK: - Private

    private func load<T: Codable>(_ type: T.Type, filename: String) -> T? {
        let url = docsDir.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func save<T: Codable>(_ data: T, filename: String) {
        let url = docsDir.appendingPathComponent(filename)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let encoded = try? encoder.encode(data) {
            try? encoded.write(to: url, options: .atomic)
        }
    }
}
