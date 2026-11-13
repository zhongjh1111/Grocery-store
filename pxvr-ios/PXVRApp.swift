//
//  PXVRApp.swift
//  PXVR-iOS
//
//  入口：在启动早期跑 PXVRStartup（签名校验 + WebView 准备 + 设备完整性采集），
//  随后完成 /xk + /xc 握手（对接真实服务器）。
//

//
//  入口说明
//
//  本工程走 UIKit 路线（AppDelegate + SceneDelegate），与 Android 版结构一致：
//    AppDelegate  -> Application.onCreate()
//    SceneDelegate -> Activity 的 rootVC 选择（登录态判断）
//
//  因此 @main 只允许出现在 PXVR/App/AppDelegate.swift 一处。
//  启动逻辑与 /xk + /xc 握手诊断已迁移至 AppDelegate.didFinishLaunchingWithOptions。
//  本文件仅保留 SwiftUI 诊断视图，供调试时手动挂载，不参与 App 启动。
//

import SwiftUI
import WebKit   // RepresentedWebView 直接暴露 WKWebView，SwiftUI 不会转导出 WebKit

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("PXVR-iOS")
                .font(.largeTitle)
            if PXVRStartup.shared.signatureOK {
                Text("签名校验通过").foregroundColor(.green)
            } else {
                Text("签名校验失败").foregroundColor(.red)
            }
            if let wv = PXVRWebView.shared.view {
                RepresentedWebView(webView: wv)
            }
        }
        .padding()
    }
}

/// 把 WKWebView 包进 SwiftUI。
struct RepresentedWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
