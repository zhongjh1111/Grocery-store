//
//  RootView.swift
//  PXVRUI
//
//  按原版观感重做：顶部 colorPrimary 色 Toolbar + WebView + 下拉刷新，
//  功能收进右上角菜单，日志默认隐藏。
//

import SwiftUI
import UIKit
import WebKit

// MARK: - WebView 包装（带下拉刷新）

struct WebViewContainer: UIViewRepresentable {
    let controller: WebController

    func makeUIView(context: Context) -> WKWebView {
        let wv = controller.webView!
        let refresh = UIRefreshControl()
        refresh.tintColor = .white
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
    @State private var server = ""
    @State private var showMenu = false
    @State private var showLogs = false
    @State private var showSheet = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            WebViewContainer(controller: controller)
            if showLogs { logPanel }
        }
        .background(PXVRTheme.background(scheme))
        .confirmationDialog("选项", isPresented: $showMenu, titleVisibility: .hidden) {
            Button("刷新") { controller.reload() }
            Button("后退") { controller.goBack() }
            Button("前进") { controller.goForward() }
            Button("地址与服务器…") { showSheet = true }
            Button(showLogs ? "隐藏日志" : "显示日志") { showLogs.toggle() }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showSheet) { sheet }
        .onAppear { controller.load(address) }
        .onChange(of: controller.currentURL) { newValue in
            if !newValue.isEmpty { address = newValue }
        }
    }

    // MARK: 顶部栏

    private var toolbar: some View {
        HStack(spacing: 18) {
            Text(controller.pageTitle.isEmpty ? "PXVR" : controller.pageTitle)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(PXVRTheme.barTitle(scheme))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            if controller.isLoading {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(PXVRTheme.barTitle(scheme))
            }

            Button { controller.reload() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(PXVRTheme.barTitle(scheme))
            }

            Button { showMenu = true } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(PXVRTheme.barTitle(scheme))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(
            PXVRTheme.primary(scheme).ignoresSafeArea(edges: .top)
        )
    }

    // MARK: 日志

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("日志")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(PXVRTheme.text(scheme))
                Spacer()
                Button("清空") { controller.clearLogs() }
                    .font(.system(size: 11))
                    .foregroundColor(PXVRTheme.link(scheme))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(controller.logs.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(PXVRTheme.text(scheme))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .frame(height: 150)
        }
        .background(PXVRTheme.card(scheme))
    }

    // MARK: 地址 / 服务器

    private var sheet: some View {
        NavigationView {
            Form {
                Section(header: Text("页面地址")) {
                    TextField("https://", text: $address)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                }

                Section(
                    header: Text("服务器"),
                    footer: Text("填入后点「连接」执行 /xk → /xc 握手，成功后自动加载下发的首页。")
                ) {
                    TextField("https://", text: $server)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)

                    Button {
                        showSheet = false
                        controller.connect(server: server)
                    } label: {
                        HStack {
                            Text("连接")
                            if controller.isConnecting {
                                Spacer()
                                ProgressView().scaleEffect(0.7)
                            }
                        }
                    }
                    .disabled(server.isEmpty || controller.isConnecting)
                }

                Section {
                    Button("打开页面地址") {
                        showSheet = false
                        controller.load(address)
                    }
                }
            }
            .navigationTitle("地址与服务器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showSheet = false }
                }
            }
        }
    }
}
