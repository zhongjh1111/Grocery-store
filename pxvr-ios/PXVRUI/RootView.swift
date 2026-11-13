//
//  RootView.swift
//  PXVRUI
//
//  地址栏 + WebView + 日志面板。
//

import SwiftUI
import WebKit
import UIKit

// MARK: - WebView 包装

struct WebViewContainer: UIViewRepresentable {
    let controller: WebController

    func makeUIView(context: Context) -> WKWebView {
        controller.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - 主界面

struct RootView: View {

    @StateObject private var controller = WebController()
    @State private var address: String = "https://www.pixiv.net"
    @State private var server: String = ""
    @State private var showLogs = true

    var body: some View {
        VStack(spacing: 0) {

            // 服务器 + 握手
            HStack(spacing: 8) {
                TextField("服务器地址（握手用）", text: $server)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
                    .font(.system(size: 13))

                Button {
                    controller.connect(server: server)
                } label: {
                    if controller.isConnecting {
                        ProgressView().scaleEffect(0.6)
                    } else {
                        Text("连接").font(.system(size: 13, weight: .semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(server.isEmpty || controller.isConnecting)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            // 地址栏
            HStack(spacing: 8) {
                TextField("输入地址", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
                    .onSubmit { controller.load(address) }

                Button {
                    controller.load(address)
                } label: {
                    Image(systemName: "arrow.right.circle.fill")
                }
                .disabled(address.isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            // 工具条
            HStack(spacing: 18) {
                Button { controller.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!controller.canGoBack)
                Button { controller.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!controller.canGoForward)
                Button { controller.reload() } label: { Image(systemName: "arrow.clockwise") }
                Spacer()
                if controller.isLoading {
                    ProgressView().scaleEffect(0.7)
                }
                Text(controller.pageTitle)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Button {
                    withAnimation { showLogs.toggle() }
                } label: {
                    Image(systemName: showLogs ? "text.bubble.fill" : "text.bubble")
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .font(.system(size: 17))

            Divider()

            // 网页
            WebViewContainer(controller: controller)
                .overlay(alignment: .top) {
                    if controller.isLoading {
                        ProgressView(value: 0.5)
                            .progressViewStyle(.linear)
                    }
                }

            // 日志
            if showLogs {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("日志（\(controller.logs.count)）")
                            .font(.caption2.weight(.semibold))
                        Spacer()
                        Button("清空") { controller.clearLogs() }
                            .font(.caption2)
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 4)

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(controller.logs.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 10, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                    }
                    .frame(height: 140)
                }
                .background(Color(.secondarySystemBackground))
            }
        }
        .onAppear {
            controller.load(address)
        }
    }
}
