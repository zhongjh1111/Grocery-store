//
//  RootView.swift
//  PXVRUI
//
//  主界面——照原版实测还原：
//    状态栏 / 工具栏同色（colorPrimary #0096FA），左侧白色标题（= 网页标题），
//    右侧单一个 ⋮ 打开溢出菜单；WebView 占满；右下角半透明「回到顶部」圆钮。
//    菜单是贴右上角的浮层（非 sheet），二级结构。
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

        @objc func onRefresh() { controller.reload() }

        func endRefreshing() {
            guard let r = refresh, r.isRefreshing else { return }
            r.endRefreshing()
        }
    }
}

// MARK: - 主界面

struct RootView: View {

    @StateObject private var controller = WebController()

    @State private var address = "https://www.pixiv.net"
    @State private var menuLevel: PXVRMenuOverlay.Level?
    @State private var showMember = false
    @State private var showAddressInput = false
    @State private var showLogs = false
    @State private var nightMode = false
    @State private var desktopMode = false
    @State private var dataSync = true
    @State private var restoreLast = false

    /// 原版 colorPrimary
    private let barBlue = Color(hex: 0x0096FA)

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                appBar
                WebViewContainer(controller: controller)
            }

            // 回到顶部
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        controller.webView?.evaluateJavaScript("window.scrollTo({top:0,behavior:'smooth'})")
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(.white)
                            .frame(width: 46, height: 46)
                            .background(Color.black.opacity(0.18))
                            .clipShape(Circle())
                    }
                    .padding(.trailing, 14)
                    .padding(.bottom, 18)
                }
            }

            // 溢出菜单
            if let level = menuLevel {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { menuLevel = nil }
                    .ignoresSafeArea()

                menuOverlay(level: level)
                    .padding(.top, 44)
            }
        }
        .sheet(isPresented: $showMember) {
            PXVRMemberView(controller: controller)
        }
        .sheet(isPresented: $showLogs) {
            PXVRLogView(controller: controller)
        }
        .alert("输入地址", isPresented: $showAddressInput) {
            TextField("https://", text: $address)
            Button("取消", role: .cancel) {}
            Button("打开") { controller.load(address) }
        }
        .onAppear {
            PXVRProxyServer.shared.start()
            // 先握手拿配置（路由表靠它），再打开页面
            controller.connect(server: "", thenLoad: address)
        }
    }

    // MARK: 工具栏

    private var appBar: some View {
        HStack {
            Text(controller.pageTitle.isEmpty ? "pixiv" : controller.pageTitle)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
                // 长按标题 → 显隐日志（原版没有日志面板，但调试需要）
                .onLongPressGesture(minimumDuration: 0.6) { showLogs.toggle() }

            Spacer()

            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    menuLevel = (menuLevel == nil) ? .main : nil
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .bold))
                    .rotationEffect(.degrees(90))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(barBlue.ignoresSafeArea(edges: .top))
    }

    // MARK: 菜单浮层

    private func menuOverlay(level: PXVRMenuOverlay.Level) -> some View {
        PXVRMenuOverlay(
            level: Binding(get: { level },
                           set: { menuLevel = $0 }),
            onBookmarks: { closeMenu(); controller.load("https://www.pixiv.net/bookmark.php") },
            onHistory: { closeMenu() },
            onDownloads: { closeMenu() },
            onAdvancedSearch: { closeMenu() },
            onInputAddress: { closeMenu(); showAddressInput = true },
            onMember: { closeMenu(); showMember = true },
            onFeedback: { closeMenu() },
            onQuit: { closeMenu() },
            nightMode: $nightMode,
            desktopMode: $desktopMode,
            dataSync: $dataSync,
            restoreLast: $restoreLast,
            onBlockSettings: { closeMenu() },
            onMoreOptions: { closeMenu() },
            onFAQ: { closeMenu() },
            onPixivHelp: { closeMenu() },
            onCheckUpdate: { closeMenu() },
            onAbout: { closeMenu() },
            onHome: { closeMenu(); controller.load(address) },
            onReload: { closeMenu(); controller.reload() }
        )
    }

    private func closeMenu() { menuLevel = nil }
}

// MARK: - 分享

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
