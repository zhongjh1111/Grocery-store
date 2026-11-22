//
//  PXVRPages.swift
//  PXVRUI
//
//  主菜单里那些入口背后的页面：书签 / 历史 / 下载 / 高级搜索 / 屏蔽 / 关于。
//  数据层复用 PXVR/Managers/DataManager（书签、历史、下载、设置均已持久化）。
//

import SwiftUI
import UIKit

// MARK: - 通用页壳

private struct PageShell<Content: View>: View {
    let title: String
    @Environment(\.dismiss) var dismiss
    let content: () -> Content

    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        NavigationView {
            content()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("关闭") { dismiss() }
                    }
                }
        }
    }
}

// MARK: - 书签

struct PXVRBookmarksPage: View {
    let onOpen: (String) -> Void
    @State private var items: [Bookmark] = DataManager.shared.loadBookmarks()

    var body: some View {
        PageShell(title: "查看书签") {
            Group {
                if items.isEmpty {
                    empty("暂无书签")
                } else {
                    List {
                        ForEach(items) { b in
                            Button {
                                onOpen(b.url)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(b.title.isEmpty ? b.url : b.title)
                                        .font(.system(size: 15)).foregroundColor(.primary)
                                    Text(b.url).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .onDelete { idx in
                            for i in idx { DataManager.shared.removeBookmark(url: items[i].url) }
                            items = DataManager.shared.loadBookmarks()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 历史

struct PXVRHistoryPage: View {
    let onOpen: (String) -> Void
    @State private var items: [HistoryItem] = DataManager.shared.loadHistory()

    var body: some View {
        PageShell(title: "浏览历史") {
            Group {
                if items.isEmpty {
                    empty("暂无记录")
                } else {
                    List {
                        ForEach(items) { h in
                            Button {
                                onOpen(h.url)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(h.title.isEmpty ? h.url : h.title)
                                        .font(.system(size: 15)).foregroundColor(.primary)
                                    Text(h.url).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .onDelete { idx in
                            for i in idx {
                                var all = DataManager.shared.loadHistory()
                                all.removeAll { $0.id == items[i].id }
                                DataManager.shared.saveHistory(all)
                            }
                            items = DataManager.shared.loadHistory()
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("清空") {
                        DataManager.shared.clearHistory()
                        items = []
                    }
                }
            }
        }
    }
}

// MARK: - 下载

struct PXVRDownloadsPage: View {
    let onOpen: (String) -> Void
    @State private var items: [DownloadItem] = DataManager.shared.loadDownloads()

    private func statusText(_ st: DownloadStatus) -> String {
        switch st {
        case .done:       return "已完成"
        case .inProgress: return "下载中"
        case .failed:     return "失败"
        }
    }

    var body: some View {
        PageShell(title: "下载管理器") {
            Group {
                if items.isEmpty {
                    empty("暂无下载")
                } else {
                    List {
                        ForEach(items) { d in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(d.title).font(.system(size: 15)).lineLimit(1)
                                Text(statusText(d.status))
                                    .font(.system(size: 12)).foregroundColor(.secondary)
                            }
                        }
                        .onDelete { idx in
                            for i in idx { DataManager.shared.removeDownload(id: items[i].id) }
                            items = DataManager.shared.loadDownloads()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 高级搜索

struct PXVRSearchPage: View {
    let onSearch: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var keyword = ""
    @State private var order = 0        // 0 最新 / 1 热门
    @State private var kind = 0         // 0 全部 / 1 插画 / 2 漫画
    @State private var match = 0        // 0 标签 / 1 标签+标题 / 2 标题简介

    var body: some View {
        PageShell(title: "高级搜索") {
            Form {
                Section {
                    TextField("关键词", text: $keyword)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section {
                    Picker("排序", selection: $order) {
                        Text("最新").tag(0); Text("热门").tag(1)
                    }
                    Picker("类型", selection: $kind) {
                        Text("全部").tag(0); Text("插画").tag(1); Text("漫画").tag(2)
                    }
                    Picker("匹配", selection: $match) {
                        Text("标签").tag(0); Text("标签+标题").tag(1); Text("标题/简介").tag(2)
                    }
                }
                Section {
                    Button("搜索") {
                        guard !keyword.isEmpty else { return }
                        onSearch(buildURL())
                        dismiss()
                    }
                }
            }
        }
    }

    private func buildURL() -> String {
        let orderV = order == 0 ? "date_d" : "popular_d"
        let modeV: String
        switch kind {
        case 1: modeV = "illust_and_ugoira"
        case 2: modeV = "manga"
        default: modeV = "all"
        }
        let smode = match == 0 ? "s_tag" : (match == 1 ? "s_tag_full" : "s_tc")
        let kw = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        return "https://www.pixiv.net/search.php?word=\(kw)&order=\(orderV)&mode=\(modeV)&s_mode=\(smode)"
    }
}

// MARK: - 屏蔽设置

struct PXVRBlockPage: View {
    @State private var text: String = DataManager.shared.getSetting("blockTags", defaultValue: "")
    @State private var saved = false

    var body: some View {
        PageShell(title: "屏蔽设置") {
            Form {
                Section(header: Text("屏蔽的标签（每行一个）")) {
                    TextEditor(text: $text)
                        .frame(minHeight: 180)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section {
                    Button("保存") {
                        DataManager.shared.setSetting("blockTags", value: text)
                        saved = true
                    }
                    if saved {
                        Text("已保存，刷新页面后生效")
                            .font(.system(size: 12)).foregroundColor(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - 关于

struct PXVRAboutPage: View {
    private var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "-"
    }
    private var build: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "-"
    }

    var body: some View {
        PageShell(title: "关于") {
            List {
                Section {
                    row("版本", version)
                    row("构建", build)
                    row("服务器", "PXVR")
                }
                Section {
                    row("服务协议", "见官网")
                    row("开源组件", "SwiftUI / Network")
                }
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k)
            Spacer()
            Text(v).foregroundColor(.secondary)
        }
        .font(.system(size: 15))
    }
}

// MARK: - 空态

private func empty(_ text: String) -> some View {
    VStack(spacing: 8) {
        Image(systemName: "tray").font(.system(size: 34)).foregroundColor(.secondary)
        Text(text).font(.system(size: 14)).foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}
