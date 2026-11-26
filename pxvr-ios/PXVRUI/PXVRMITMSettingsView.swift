//
//  PXVRMITMSettingsView.swift
//  PXVRUI
//
//  连接方式设置。三种通道并存，各自标注完工状态。
//

import SwiftUI

/// 三种连接通道
enum PXVRChannel: String, CaseIterable, Identifiable {
    case rewrite   // URL 改写（最早那套，边角未完工）
    case hook      // 进程内拦截（WKBCC，实验）
    case mitm      // 系统代理 + 自签证书

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rewrite: return "URL 改写"
        case .hook:    return "进程内拦截"
        case .mitm:    return "系统代理 + 证书"
        }
    }

    var badge: String {
        switch self {
        case .rewrite: return "未完工"
        case .hook:    return "实验"
        case .mitm:    return "未完工"
        }
    }

    var detail: String {
        switch self {
        case .rewrite:
            return "页面地址被改写成本地转发，图片与登录仍不稳定。目前唯一能打开页面的通道。"
        case .hook:
            return "在 App 内注册 WKWebView 的 https 拦截，URL 保持原样。转发层尚未补齐 Cookie 与多值响应头。"
        case .mitm:
            return "需要安装根证书并把 Wi-Fi 代理指向本机。会影响其他 App，仅作调试用。"
        }
    }

    static var current: PXVRChannel {
        get { PXVRChannel(rawValue: UserDefaults.standard.string(forKey: "pxvr.channel") ?? "") ?? .rewrite }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "pxvr.channel") }
    }
}

struct PXVRMITMSettingsView: View {
    @ObservedObject var controller: WebController
    @Environment(\.dismiss) private var dismiss

    @State private var channel: PXVRChannel = .current
    @State private var mitmOn = UserDefaults.standard.bool(forKey: "pxvr.mitm")

    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(PXVRChannel.allCases) { c in
                        Button {
                            select(c)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: channel == c ? "largecircle.fill.circle" : "circle")
                                    .foregroundColor(channel == c ? Color(hex: 0x1E88E5) : .secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(c.title).foregroundColor(.primary)
                                        Text(c.badge)
                                            .font(.system(size: 10))
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(Color(hex: 0xFFF3CD))
                                            .foregroundColor(Color(hex: 0x8A6D3B))
                                            .cornerRadius(3)
                                    }
                                    Text(c.detail)
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("连接方式")
                } footer: {
                    Text("切换后需要重新加载页面；拦截模式需要重新打开一次开关才生效。")
                        .font(.system(size: 12))
                }

                if channel == .hook {
                    Section("拦截状态") {
                        Text(controller.hookStateText)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                        Button("重新注册并加载首页") {
                            controller.enableHookAndReload()
                        }
                    }
                }

                if channel == .mitm {
                    Section("系统代理（调试用）") {
                        Toggle("启用本地 MITM 服务", isOn: $mitmOn)
                            .onChange(of: mitmOn) { on in
                                UserDefaults.standard.set(on, forKey: "pxvr.mitm")
                                if on {
                                    let ok = PXVRMITMServer.shared.start()
                                    controller.append(ok ? "[mitm] 已启动 127.0.0.1:\(PXVRMITMServer.shared.port)"
                                                         : "[mitm] 启动失败（端口占用？）")
                                } else {
                                    PXVRMITMServer.shared.stop()
                                }
                            }
                        Button("导出 CA 证书") {
                            if let u = Bundle.main.url(forResource: "ca", withExtension: "der") {
                                PXVRShare.present([u])
                            }
                        }
                        Text("装完证书后到「设置 → 通用 → 关于本机 → 证书信任设置」打开完全信任。")
                            .font(.system(size: 12)).foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("连接方式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func select(_ c: PXVRChannel) {
        channel = c
        PXVRChannel.current = c   // enabled 由通道推导，不要单独写
        if c == .hook {
            controller.enableHookAndReload()
        } else {
            controller.append("[mode] 切换到 \(c.title)（\(c.badge)）")
            controller.reloadHome()
        }
    }
}
