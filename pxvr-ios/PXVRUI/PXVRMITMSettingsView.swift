//
//  PXVRMITMSettingsView.swift
//  PXVRUI
//
//  MITM 代理的开关与指引页。
//

import SwiftUI

struct PXVRMITMSettingsView: View {
    @ObservedObject var controller: WebController
    @Environment(\.dismiss) private var dismiss

    @State private var enabled = UserDefaults.standard.bool(forKey: "pxvr.mitm")
    @State private var intercept = PXVRURLProtocol.enabled
    @State private var caURL: URL?

    var body: some View {
        NavigationView {
            List {
                Section {
                    Toggle("进程内拦截（推荐）", isOn: $intercept)
                        .onChange(of: intercept) { on in
                            PXVRURLProtocol.enabled = on
                            if on { PXVRURLProtocol.install() }
                            let state = on ? "已开启" : "已关闭"
                            controller.append("[hook] 拦截模式 \(state)，重启 App 后完全生效")
                        }
                } header: {
                    Text("方式一：进程内拦截")
                } footer: {
                    Text("只影响本 App，不需要装证书、不需要改 Wi-Fi 代理。页面 URL 保持原样。")
                        .font(.system(size: 12))
                }

                Section {
                    Toggle("启用本地代理（MITM）", isOn: $enabled)
                        .onChange(of: enabled) { on in
                            UserDefaults.standard.set(on, forKey: "pxvr.mitm")
                            if on {
                                let ok = PXVRMITMServer.shared.start()
                                controller.append(ok ? "[mitm] 已启动 127.0.0.1:\(PXVRMITMServer.shared.port)"
                                                     : "[mitm] 启动失败（端口占用？）")
                            } else {
                                PXVRMITMServer.shared.stop()
                                controller.append("[mitm] 已停止")
                            }
                        }
                    if PXVRMITMServer.shared.running {
                        Text("代理地址：127.0.0.1:\(PXVRMITMServer.shared.port == 0 ? 8899 : PXVRMITMServer.shared.port)")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                } footer: {
                    Text("开启后页面不再改写 URL。需要在 Wi-Fi 设置里把代理指向这里，并信任证书。")
                        .font(.system(size: 12))
                }

                Section("方式二（备选）：系统代理 —— 需要装证书") {
                    Button("导出 CA 证书") {
                        caURL = Bundle.main.url(forResource: "ca", withExtension: "der")
                        if let u = caURL { PXVRShare.present([u]) }
                    }
                    Text("用 Filza 把 ca.der 放到设备并安装描述文件，然后到「设置 → 通用 → 关于本机 → 证书信任设置」里打开完全信任。")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                Section("第二步：设置系统代理") {
                    Text("设置 → 无线局域网 → 当前 Wi-Fi → 配置代理 → 手动\n服务器 127.0.0.1，端口 \(PXVRMITMServer.shared.port == 0 ? 8899 : PXVRMITMServer.shared.port)")
                        .font(.system(size: 13, design: .monospaced))
                }

                Section {
                    Text("越狱机可以用 truststore 直接装证书，并改写 Wi-Fi 代理配置，省掉手动步骤。")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("本地代理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
