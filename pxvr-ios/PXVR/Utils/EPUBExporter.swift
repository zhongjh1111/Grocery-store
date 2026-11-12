import Foundation
import UIKit

/// EPUB 导出器 — 对应 Android 端的 EPUB Generator
/// 将 Pixiv 小说导出为 EPUB 格式
class EPUBExporter {

    /// 导出小说为 EPUB
    static func exportNovel(
        novelId: String,
        title: String,
        author: String,
        text: String,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            do {
                let epubURL = try generateEPUB(
                    novelId: novelId,
                    title: title,
                    author: author,
                    text: text
                )
                DispatchQueue.main.async {
                    completion(.success(epubURL))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    /// 导出小说系列为 EPUB
    static func exportNovelSeries(
        seriesId: String,
        title: String,
        novels: [(id: String, title: String, text: String)],
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            do {
                let epubURL = try generateSeriesEPUB(
                    seriesId: seriesId,
                    title: title,
                    novels: novels
                )
                DispatchQueue.main.async {
                    completion(.success(epubURL))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - EPUB Generation

    private static func generateEPUB(novelId: String, title: String, author: String, text: String) throws -> URL {
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let epubDir = docsDir.appendingPathComponent("PXVR/EPUB", isDirectory: true)
        try? FileManager.default.createDirectory(at: epubDir, withIntermediateDirectories: true)

        let epubURL = epubDir.appendingPathComponent("\(novelId)_\(sanitize(title)).epub")

        // EPUB 是 ZIP 文件
        // 结构:
        //   mimetype
        //   META-INF/container.xml
        //   OEBPS/content.opf
        //   OEBPS/toc.ncx
        //   OEBPS/stylesheet.css
        //   OEBPS/novel.xhtml

        let htmlText = textToHTML(text)

        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """

        let contentOPF = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="2.0">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
                <dc:title>\(escapeXML(title))</dc:title>
                <dc:creator>\(escapeXML(author))</dc:creator>
                <dc:language>zh</dc:language>
                <dc:identifier id="bookid">pxvr-novel-\(novelId)</dc:identifier>
                <meta name="generator" content="PXVR EPUB Generator"/>
            </metadata>
            <manifest>
                <item id="stylesheet" href="stylesheet.css" media-type="text/css"/>
                <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
                <item id="novel" href="novel.xhtml" media-type="application/xhtml+xml"/>
            </manifest>
            <spine toc="ncx">
                <itemref idref="novel"/>
            </spine>
        </package>
        """

        let tocNCX = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
            <head>
                <meta name="dtb:uid" content="pxvr-novel-\(novelId)"/>
            </head>
            <docTitle><text>\(escapeXML(title))</text></docTitle>
            <navMap>
                <navPoint id="navpoint-1" playOrder="1">
                    <navLabel><text>\(escapeXML(title))</text></navLabel>
                    <content src="novel.xhtml"/>
                </navPoint>
            </navMap>
        </ncx>
        """

        let css = """
        body {
            font-family: "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", serif;
            line-height: 1.8;
            font-size: 1em;
            margin: 1em;
        }
        h1 { font-size: 1.5em; text-align: center; margin-bottom: 1em; }
        p { text-indent: 2em; margin: 0.5em 0; }
        """

        let xhtml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
        <html xmlns="http://www.w3.org/1999/xhtml">
            <head>
                <title>\(escapeXML(title))</title>
                <link rel="stylesheet" type="text/css" href="stylesheet.css"/>
            </head>
            <body>
                <h1>\(escapeXML(title))</h1>
                \(htmlText)
            </body>
        </html>
        """

        // 写入临时目录再打包
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("epub_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let oebpsDir = tempDir.appendingPathComponent("OEBPS", isDirectory: true)
        let metaDir = tempDir.appendingPathComponent("META-INF", isDirectory: true)
        try FileManager.default.createDirectory(at: oebpsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metaDir, withIntermediateDirectories: true)

        // mimetype (不压缩)
        try "application/epub+zip".data(using: .utf8)!.write(to: tempDir.appendingPathComponent("mimetype"))
        try containerXML.data(using: .utf8)!.write(to: metaDir.appendingPathComponent("container.xml"))
        try contentOPF.data(using: .utf8)!.write(to: oebpsDir.appendingPathComponent("content.opf"))
        try tocNCX.data(using: .utf8)!.write(to: oebpsDir.appendingPathComponent("toc.ncx"))
        try css.data(using: .utf8)!.write(to: oebpsDir.appendingPathComponent("stylesheet.css"))
        try xhtml.data(using: .utf8)!.write(to: oebpsDir.appendingPathComponent("novel.xhtml"))

        // 打包为 ZIP (EPUB)
        try zipDirectory(at: tempDir, to: epubURL)

        // 清理临时目录
        try? FileManager.default.removeItem(at: tempDir)

        return epubURL
    }

    private static func generateSeriesEPUB(seriesId: String, title: String, novels: [(id: String, title: String, text: String)]) throws -> URL {
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let epubDir = docsDir.appendingPathComponent("PXVR/EPUB", isDirectory: true)
        try? FileManager.default.createDirectory(at: epubDir, withIntermediateDirectories: true)

        let epubURL = epubDir.appendingPathComponent("series_\(seriesId)_\(sanitize(title)).epub")

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("epub_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let oebpsDir = tempDir.appendingPathComponent("OEBPS", isDirectory: true)
        let metaDir = tempDir.appendingPathComponent("META-INF", isDirectory: true)
        try FileManager.default.createDirectory(at: oebpsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metaDir, withIntermediateDirectories: true)

        try "application/epub+zip".data(using: .utf8)!.write(to: tempDir.appendingPathComponent("mimetype"))

        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        try containerXML.data(using: .utf8)!.write(to: metaDir.appendingPathComponent("container.xml"))

        // 生成每章的 XHTML
        var manifestItems = ""
        var spineItems = ""
        var navPoints = ""

        for (index, novel) in novels.enumerated() {
            let chapterFile = "chapter\(index + 1).xhtml"
            let htmlText = textToHTML(novel.text)
            let chapterXHTML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
            <html xmlns="http://www.w3.org/1999/xhtml">
                <head><title>\(escapeXML(novel.title))</title><link rel="stylesheet" type="text/css" href="stylesheet.css"/></head>
                <body><h1>\(escapeXML(novel.title))</h1>\(htmlText)</body>
            </html>
            """
            try chapterXHTML.data(using: .utf8)!.write(to: oebpsDir.appendingPathComponent(chapterFile))

            manifestItems += "<item id=\"ch\(index + 1)\" href=\"\(chapterFile)\" media-type=\"application/xhtml+xml\"/>"
            spineItems += "<itemref idref=\"ch\(index + 1)\"/>"
            navPoints += """
            <navPoint id="navpoint-\(index + 1)" playOrder="\(index + 1)">
                <navLabel><text>\(escapeXML(novel.title))</text></navLabel>
                <content src="\(chapterFile)"/>
            </navPoint>
            """
        }

        let contentOPF = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="2.0">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
                <dc:title>\(escapeXML(title))</dc:title>
                <dc:language>zh</dc:language>
                <dc:identifier id="bookid">pxvr-series-\(seriesId)</dc:identifier>
                <meta name="generator" content="PXVR EPUB Generator"/>
            </metadata>
            <manifest>
                <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
                <item id="stylesheet" href="stylesheet.css" media-type="text/css"/>
                \(manifestItems)
            </manifest>
            <spine toc="ncx">\(spineItems)</spine>
        </package>
        """
        try contentOPF.data(using: .utf8)!.write(to: oebpsDir.appendingPathComponent("content.opf"))

        let tocNCX = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
            <head><meta name="dtb:uid" content="pxvr-series-\(seriesId)"/></head>
            <docTitle><text>\(escapeXML(title))</text></docTitle>
            <navMap>\(navPoints)</navMap>
        </ncx>
        """
        try tocNCX.data(using: .utf8)!.write(to: oebpsDir.appendingPathComponent("toc.ncx"))

        let css = """
        body { font-family: "PingFang SC", "Hiragino Sans GB", serif; line-height: 1.8; margin: 1em; }
        h1 { font-size: 1.5em; text-align: center; }
        p { text-indent: 2em; margin: 0.5em 0; }
        """
        try css.data(using: .utf8)!.write(to: oebpsDir.appendingPathComponent("stylesheet.css"))

        try zipDirectory(at: tempDir, to: epubURL)
        try? FileManager.default.removeItem(at: tempDir)

        return epubURL
    }

    // MARK: - Helpers

    private static func textToHTML(_ text: String) -> String {
        let paragraphs = text.components(separatedBy: "\n")
        return paragraphs
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { "<p>\(escapeXML($0))</p>" }
            .joined(separator: "\n")
    }

    private static func escapeXML(_ str: String) -> String {
        return str
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func sanitize(_ filename: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return filename.components(separatedBy: invalid).joined(separator: "_")
    }

    private static func zipDirectory(at source: URL, to destination: URL) throws {
        // 使用 Process 调用 zip 命令 (macOS 上可用)
        // 或者手动构建 ZIP
        // 这里用 FileManager 的 coordinated write 配合 ZipArchive 风格
        // 实际实现需要 ZipArchive 或 SSZipArchive 库
        // 为了不依赖第三方库，我们用 zip 命令行工具

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", "-X", destination.path, ".", "-x", "mimetype"]
        process.currentDirectoryURL = source

        // 先存 mimetype (不压缩)
        let epubData = "application/epub+zip".data(using: .utf8)!
        var zipData = Data([0x50, 0x4B, 0x05, 0x06]) // Local file header signature
        // 实际上直接用 zip 命令更简单

        // 简化：直接把整个目录 zip 起来
        try? FileManager.default.removeItem(at: destination)

        // 用 zip 命令打包 (macOS/Linux)
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/zip") {
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()
        } else {
            // 如果没有 zip 命令，用 Python 的 zipfile
            try zipWithPython(source: source, destination: destination)
        }
    }

    private static func zipWithPython(source: URL, destination: URL) throws {
        let pythonScript = """
        import zipfile, os
        with zipfile.ZipFile('\(destination.path)', 'w', zipfile.ZIP_DEFLATED) as zf:
            # mimetype first, stored (not compressed)
            mt_path = os.path.join('\(source.path)', 'mimetype')
            if os.path.exists(mt_path):
                zf.write(mt_path, 'mimetype', zipfile.ZIP_STORED)
            # all other files
            for root, dirs, files in os.walk('\(source.path)'):
                for f in files:
                    if f == 'mimetype':
                        continue
                    full = os.path.join(root, f)
                    arc = os.path.relpath(full, '\(source.path)')
                    zf.write(full, arc, zipfile.ZIP_DEFLATED)
        """

        let tempScript = FileManager.default.temporaryDirectory.appendingPathComponent("zip_\(UUID().uuidString).py")
        try pythonScript.data(using: .utf8)!.write(to: tempScript)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [tempScript.path]
        try process.run()
        process.waitUntilExit()

        try? FileManager.default.removeItem(at: tempScript)
    }
}
