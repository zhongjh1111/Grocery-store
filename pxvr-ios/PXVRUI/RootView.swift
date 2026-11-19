//
//  RootView.swift
//  PXVRUI
//
//  主界面骨架。参照原版：
//    顶部栏（后退 / 前进 / 标题 / 刷新 / 主菜单）
//    WebView 内容区
//    右上角「主菜单」→ 我的大会员 / 下载 / 设置…
//  下拉刷新沿用 UIRefreshControl，与原版一致。
//

import SwiftUI
import WebKit
import UIKit

// MARK: - WebView 包装（带下拉刷新）

struct WebViewContainer: UIViewRepresentable {
    let controller: WebController

    func makeUIView(context: Context) -> WKWebView {
        let wv = controller.webView!
        let refresh = UIRefreshControl()
        refresh.tintColor = UIColor(PXVRTheme.accent)
        refresh.addTarget(context.coordinator,
                          action: #selector(Coordinator.onRefresh),
                          for: .valueChanged)
        wv.scrollView.refreshControl = refresh
        context.coordinator.refresh = refresh
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if !controller.isLoading { context.coordinator.endRefreshing() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    final class Coordinator: NSObject {
        weak var refresh: UIRefreshControl?
        private let controller: WebController

        init(controller: WebController) {
            self.controller = controller
        }

        @objc func onRefresh() {
            controller.reload()
        }

        func endRefreshing() {
            guard let r = refresh, r.isRefreshing else { return }
            r.endRefreshing()
        }
    }
}

// MARK: - 主界面

struct RootView: View {

    @Environment(\.colorScheme) private var scheme
    @StateObject private var controller = WebController()

    @State private var address = "https://www.pixiv.net"
    @State private var showMenu = false
    @State private var showMember = false
    @State private var showLogs = false
    @State private var showAddressBar = false
    @State private var exportURL: URL?
    @State private var showExport = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if showAddressBar { addressBar }
            WebViewContainer(controller: controller)
            if showLogs { logPanel }
        }
        .background(PXVRTheme.bg(scheme).ignoresSafeArea())
        .sheet(isPresented: $showMenu) {
            PXVRMenuView(
                onMember: { showMember = true },
                onReload: { controller.reload() },
                onToggleDesktop: { controller.toggleDesktopMode() },
                onExportLog: { exportURL = controller.exportLogURL(); showExport = true }
            )
        }
        .sheet(isPresented: $showMember) {
            PXVRMemberView(controller: controller)
        }
        .sheet(isPresented: $showExport) {
            if let u = exportURL { ActivityView(activityItems: [u]) }
        }
        .onAppear {
            PXVRProxyServer.shared.start()
            controller.load(address)
        }
    }

    // MARK: 顶部栏

    private var topBar: some View {
        HStack(spacing: 16) {
            Button { controller.goBack() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(controller.canGoBack ? PXVRTheme.text(scheme) : PXVRTheme.sub(scheme))
            }
            .disabled(!controller.canGoBack)

            Button { controller.goForward() } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(controller.canGoForward ? PXVRTheme.text(scheme) : PXVRTheme.sub(scheme))
            }
            .disabled(!controller.canGoForward)

            Button { showAddressBar.toggle() } label: {
                Text(controller.pageTitle.isEmpty ? "PXVR" : controller.pageTitle)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .foregroundColor(PXVRTheme.text(scheme))
            }

            Spacer()

            Button { controller.reload() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16))
                    .foregroundColor(PXVRTheme.text(scheme))
            }

            Button { showMenu = true } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 17))
                    .foregroundColor(PXVRTheme.text(scheme))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(PXVRTheme.bg(scheme))
    }

    // MARK: 地址栏

    private var addressBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 13))
                    .foregroundColor(PXVRTheme.sub(scheme))
                TextField("https://www.pixiv.net", text: $address)
                    .font(.system(size: 13))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onSubmit { controller.load(address) }
                Button("连接") { controller.connect(server: "") }
                    .font(.system(size: 13))
                    .foregroundColor(PXVRTheme.accent)
                Button {
                    showLogs.toggle()
                } label: {
                    Image(systemName: "doc.text")
                        .font(.system(size: 13))
                        .foregroundColor(PXVRTheme.sub(scheme))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider().background(PXVRTheme.line(scheme))
        }
        .background(PXVRTheme.card(scheme))
    }

    // MARK: 日志面板

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("日志")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(PXVRTheme.sub(scheme))
                Spacer()
                Button("复制") { UIPasteboard.general.string = controller.logText }
                    .font(.system(size: 11))
                    .foregroundColor(PXVRTheme.accent)
                Button("导出") {
                    exportURL = controller.exportLogURL()
                    showExport = true
                }
                .font(.system(size: 11))
                .foregroundColor(PXVRTheme.accent)
                Button("清空") { controller.clearLogs() }
                    .font(.system(size: 11))
                    .foregroundColor(PXVRTheme.accent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(controller.logs.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .textSelection(.enabled)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(PXVRTheme.text(scheme))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .frame(height: 140)
        }
        .background(PXVRTheme.card(scheme))
    }
}

// MARK: - 分享

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
