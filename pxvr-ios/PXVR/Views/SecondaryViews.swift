import UIKit

/// 书签列表 — 对应 Android 端 BookmarkActivity
class BookmarkViewController: UITableViewController {

    var bookmarks: [Bookmark] = []
    var onSelectBookmark: ((Bookmark) -> Void)?

    init() {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "书签"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .edit, target: self, action: #selector(toggleEdit)
        )

        loadData()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadData()
    }

    private func loadData() {
        bookmarks = DataManager.shared.loadBookmarks()
        tableView.reloadData()
    }

    @objc private func toggleEdit() {
        tableView.setEditing(!tableView.isEditing, animated: true)
    }

    // MARK: - TableView

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return bookmarks.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let bookmark = bookmarks[indexPath.row]

        var content = cell.defaultContentConfiguration()
        content.text = bookmark.title
        content.secondaryText = bookmark.url
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.font = .systemFont(ofSize: 11)
        cell.contentConfiguration = content

        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let bookmark = bookmarks[indexPath.row]
        onSelectBookmark?(bookmark)
        dismiss(animated: true)
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let delete = UIContextualAction(style: .destructive, title: "删除") { _, _, completion in
            let bookmark = self.bookmarks[indexPath.row]
            DataManager.shared.removeBookmark(url: bookmark.url)
            self.bookmarks.remove(at: indexPath.row)
            tableView.deleteRows(at: [indexPath], with: .automatic)
            completion(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }
}

/// 历史记录 — 对应 Android 端 HistoryActivity
class HistoryViewController: UITableViewController {

    var history: [HistoryItem] = []
    var onSelectHistory: ((HistoryItem) -> Void)?

    init() {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "历史"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "清空", style: .plain, target: self, action: #selector(clearAll)
        )

        loadData()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadData()
    }

    private func loadData() {
        history = DataManager.shared.loadHistory()
        tableView.reloadData()
    }

    @objc private func clearAll() {
        let alert = UIAlertController(title: "清空历史", message: "确定要清空所有历史记录吗？", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "清空", style: .destructive) { _ in
            DataManager.shared.clearHistory()
            self.history.removeAll()
            self.tableView.reloadData()
        })
        present(alert, animated: true)
    }

    // MARK: - TableView

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return history.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let item = history[indexPath.row]

        var content = cell.defaultContentConfiguration()
        content.text = item.title

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        content.secondaryText = "\(formatter.string(from: item.date)) · \(item.url)"
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.font = .systemFont(ofSize: 11)

        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = history[indexPath.row]
        onSelectHistory?(item)
        dismiss(animated: true)
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let delete = UIContextualAction(style: .destructive, title: "删除") { _, _, completion in
            var history = DataManager.shared.loadHistory()
            history.remove(at: indexPath.row)
            DataManager.shared.saveHistory(history)
            self.history.remove(at: indexPath.row)
            tableView.deleteRows(at: [indexPath], with: .automatic)
            completion(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }
}

/// 下载列表 — 对应 Android 端 DownloaderActivity
class DownloadListViewController: UITableViewController {

    var downloads: [DownloadItem] = []

    init() {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "下载"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        loadData()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadData()
    }

    private func loadData() {
        downloads = DataManager.shared.loadDownloads()
        tableView.reloadData()
    }

    // MARK: - TableView

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return downloads.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let item = downloads[indexPath.row]

        var content = cell.defaultContentConfiguration()
        content.text = item.title

        let sizeStr = item.totalSize > 0
            ? String(format: "%.1f MB", Double(item.totalSize) / 1048576.0)
            : "未知大小"

        let typeStr: String
        switch item.type {
        case .original: typeStr = "原图"
        case .preview: typeStr = "预览图"
        case .novel: typeStr = "小说"
        case .novelSeries: typeStr = "小说系列"
        case .unknown: typeStr = "未知"
        }

        let statusStr: String
        switch item.status {
        case .done: statusStr = "✓ 已完成"
        case .inProgress: statusStr = "下载中..."
        case .failed: statusStr = "✗ 失败"
        }

        content.secondaryText = "\(typeStr) · \(sizeStr) · \(statusStr)"
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.font = .systemFont(ofSize: 12)

        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        let item = downloads[indexPath.row]
        guard item.status == .done, let filePath = item.filePath,
              FileManager.default.fileExists(atPath: filePath) else {
            let alert = UIAlertController(title: "文件不存在", message: nil, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好的", style: .default))
            present(alert, animated: true)
            return
        }

        let url = URL(fileURLWithPath: filePath)

        // 图片用 QuickLook 展示
        let qlVC = QuickLookViewController()
        qlVC.fileURL = url
        present(qlVC, animated: true)
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let delete = UIContextualAction(style: .destructive, title: "删除") { _, _, completion in
            let item = self.downloads[indexPath.row]
            if let path = item.filePath {
                try? FileManager.default.removeItem(atPath: path)
            }
            DataManager.shared.removeDownload(id: item.id)
            self.downloads.remove(at: indexPath.row)
            tableView.deleteRows(at: [indexPath], with: .automatic)
            completion(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }
}

/// 简单的文件预览 (QuickLook)
class QuickLookViewController: UIViewController {
    var fileURL: URL!

    override func viewDidLoad() {
        super.viewDidLoad()

        let webView = WKWebView()
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())

        let closeBtn = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(close))
        navigationItem.leftBarButtonItem = closeBtn
        title = fileURL.lastPathComponent
    }

    @objc private func close() {
        dismiss(animated: true)
    }
}

import WebKit

/// 设置界面
class SettingsViewController: UITableViewController {

    private let settings = [
        ("清除缓存", "清除 WebView 缓存和 Cookie"),
        ("退出登录", "清除登录状态并返回登录页"),
        ("关于", "PXVR for iOS\n发现者: WorkBuddy AI"),
    ]

    init() {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "设置"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return settings.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let (title, desc) = settings[indexPath.row]

        var content = cell.defaultContentConfiguration()
        content.text = title
        content.secondaryText = desc
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.font = .systemFont(ofSize: 12)
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        switch indexPath.row {
        case 0: // 清除缓存
            let alert = UIAlertController(title: "清除缓存", message: "确定要清除所有缓存吗？", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            alert.addAction(UIAlertAction(title: "清除", style: .destructive) { _ in
                let store = WKWebsiteDataStore.default()
                store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
                    store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records) {
                        self.showAlert(title: "已清除", message: "缓存已清除")
                    }
                }
            })
            present(alert, animated: true)

        case 1: // 退出登录
            let alert = UIAlertController(title: "退出登录", message: "确定要退出登录吗？", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            alert.addAction(UIAlertAction(title: "退出", style: .destructive) { _ in
                CookieManager.shared.clearAll()
                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let delegate = scene.delegate as? SceneDelegate {
                    delegate.window?.rootViewController = LoginViewController()
                }
            })
            present(alert, animated: true)

        case 2: // 关于
            showAlert(title: "关于 PXVR", message: "PXVR for iOS v1.0\nPixiv 第三方客户端\n\n发现者: WorkBuddy AI\n基于 Android 版逆向分析重写")

        default: break
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好的", style: .default))
        present(alert, animated: true)
    }
}
