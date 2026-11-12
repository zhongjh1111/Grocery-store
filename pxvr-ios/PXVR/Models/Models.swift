import Foundation

// MARK: - Bookmark

struct Bookmark: Codable, Identifiable {
    var id: UUID
    var title: String
    var url: String
    var workId: String?
    var thumbUrl: String?
    var date: Date

    init(title: String, url: String, workId: String? = nil, thumbUrl: String? = nil) {
        self.id = UUID()
        self.title = title
        self.url = url
        self.workId = workId
        self.thumbUrl = thumbUrl
        self.date = Date()
    }
}

// MARK: - History

struct HistoryItem: Codable, Identifiable {
    var id: UUID
    var title: String
    var url: String
    var workId: String?
    var date: Date

    init(title: String, url: String, workId: String? = nil) {
        self.id = UUID()
        self.title = title
        self.url = url
        self.workId = workId
        self.date = Date()
    }
}

// MARK: - Download

enum DownloadType: Int, Codable {
    case unknown = 0
    case original = 1
    case preview = 2
    case novel = 3
    case novelSeries = 4
}

enum DownloadStatus: Int, Codable {
    case failed = 0
    case inProgress = 1
    case done = 2
}

struct DownloadItem: Codable, Identifiable {
    var id: UUID
    var workId: String
    var picId: Int
    var title: String
    var url: String
    var refUrl: String
    var filePath: String?
    var cookieInfo: String?
    var type: DownloadType
    var status: DownloadStatus
    var totalSize: Int64
    var finishedSize: Int64
    var timestamp: Date

    init(workId: String, url: String, title: String, type: DownloadType = .original) {
        self.id = UUID()
        self.workId = workId
        self.picId = 0
        self.title = title
        self.url = url
        self.refUrl = "https://www.pixiv.net/artworks/\(workId)"
        self.filePath = nil
        self.cookieInfo = nil
        self.type = type
        self.status = .inProgress
        self.totalSize = 0
        self.finishedSize = 0
        self.timestamp = Date()
    }
}

// MARK: - Pixiv Illust

struct PixivIllust: Codable {
    let id: String
    let title: String
    let userId: String
    let userName: String
    let url: String
    let tags: [String]
    let pageCount: Int
    let createDate: String?

    var pixivURL: String { "https://www.pixiv.net/artworks/\(id)" }
}

// MARK: - Pixiv Novel

struct PixivNovel: Codable {
    let id: String
    let title: String
    let userName: String
    let seriesTitle: String?
    let text: String?
    let tags: [String]

    var pixivURL: String { "https://www.pixiv.net/novel/show.php?id=\(id)" }
}
