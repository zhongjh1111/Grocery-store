import UIKit
import WebKit

/// Ugoira 动图播放器 — 对应 Android 端 UgoiraPlayerActivity
/// Pixiv Ugoira 是一个 ZIP 包含多帧图片 + 帧延迟信息
class UgoiraPlayerViewController: UIViewController {

    private var webView: WKWebView!
    private var frames: [(url: String, delay: Int)] = []
    private var workId: String!

    // MARK: - Init

    init(workId: String, frames: [(url: String, delay: Int)]) {
        self.workId = workId
        self.frames = frames
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // 使用 WebView 播放 Ugoira (和 Android 端一样用 HTML)
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.backgroundColor = .black
        view.addSubview(webView)

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(close)
        )
        title = "Ugoira #\(workId ?? "")"

        loadUgoira()
    }

    private func loadUgoira() {
        // 构建 Ugoira 播放 HTML (对应 Android 的 ugoira.html)
        let framesJS = frames.enumerated().map { index, frame in
            """
            {url: "\(frame.url)", delay: \(frame.delay)}
            """
        }.joined(separator: ",\n")

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        <style>
            body { margin:0; padding:0; background:#000; overflow:hidden; }
            #ugoira { position:absolute; top:50%; left:50%; transform:translate(-50%,-50%); max-width:100%; max-height:100%; }
        </style>
        </head>
        <body>
        <img id="ugoira" src="">
        <script>
        var frames = [\(framesJS)];
        var currentFrame = 0;
        var img = document.getElementById('ugoira');

        function playFrame() {
            if (currentFrame >= frames.length) currentFrame = 0;
            img.src = frames[currentFrame].url;
            var delay = frames[currentFrame].delay;
            currentFrame++;
            setTimeout(playFrame, delay);
        }

        if (frames.length > 0) {
            playFrame();
        }
        </script>
        </body>
        </html>
        """

        webView.loadHTMLString(html, baseURL: URL(string: "https://www.pixiv.net/"))
    }

    @objc private func close() {
        dismiss(animated: true)
    }
}

// MARK: - Ugoira Loader

/// Ugoira 加载器 — 获取 Ugoira 的帧信息
class UgoiraLoader {

    /// 从 pixiv API 获取 Ugoira 帧信息
    static func loadUgoiraFrames(workId: String, completion: @escaping (Result<[(url: String, delay: Int)], Error>) -> Void) {
        NetworkManager.shared.fetchIllustDetail(illustId: workId) { result in
            switch result {
            case .success(let body):
                // 解析 Ugoira 帧信息
                // API 返回格式: body.illust_details.ugoira_meta
                guard let illustDetails = body["illust_details"] as? [String: Any],
                      let ugoiraMeta = illustDetails["ugoira_meta"] as? [String: Any],
                      let frames = ugoiraMeta["frames"] as? [[String: Any]],
                      let zipURL = ugoiraMeta["src"] as? String else {

                    // 尝试另一种格式
                    if let ugoiraMeta = body["ugoira_meta"] as? [String: Any],
                       let frames = ugoiraMeta["frames"] as? [[String: Any]] {
                        let frameData = frames.compactMap { frame -> (url: String, delay: Int)? in
                            guard let file = frame["file"] as? String,
                                  let delay = frame["delay"] as? Int else { return nil }
                            return (url: file, delay: delay)
                        }
                        if !frameData.isEmpty {
                            completion(.success(frameData))
                            return
                        }
                    }

                    completion(.failure(NSError(domain: "PXVR", code: -1, message: "No ugoira data")))
                    return
                }

                let frameData = frames.compactMap { frame -> (url: String, delay: Int)? in
                    guard let file = frame["file"] as? String,
                          let delay = frame["delay"] as? Int else { return nil }
                    return (url: file, delay: delay)
                }

                if frameData.isEmpty {
                    completion(.failure(NSError(domain: "PXVR", code: -2, message: "No frames")))
                } else {
                    completion(.success(frameData))
                }

            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
}
