//
//  PXVRUIApp.swift
//  PXVRUI
//
//  独立的 UI 壳，用来在真机上验证 WebView + Sensei 桥。
//  不含加密层、不含协议实现，可以单独打包成 ipa 安装。
//

import SwiftUI

@main
struct PXVRUIApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
