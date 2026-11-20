//
//  PXVRMenuView.swift
//  PXVRUI
//
//  右上角「主菜单」。条目文案取自原包 resources.arsc。
//

import SwiftUI

struct PXVRMenuView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    let onMember: () -> Void
    let onReload: () -> Void
    let onToggleDesktop: () -> Void
    let onExportLog: () -> Void

    @State private var desktopMode = false
    @State private var nightMode = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    Button { dismiss(); onMember() } label: {
                        row("我的大会员", icon: "crown", tint: PXVRUITheme.accent)
                    }
                    row("下载管理器", icon: "arrow.down.circle")
                    row("搜索标题或标签", icon: "magnifyingglass")
                    row("标签", icon: "tag")
                }

                Section {
                    Toggle(isOn: $desktopMode) {
                        Label("桌面版页面", systemImage: "desktopcomputer")
                    }
                    .onChange(of: desktopMode) { _ in onToggleDesktop() }

                    Toggle(isOn: $nightMode) {
                        Label("夜间模式", systemImage: "moon")
                    }
                }

                Section {
                    Button { dismiss(); onReload() } label: {
                        row("刷新", icon: "arrow.clockwise")
                    }
                    Button { dismiss(); onExportLog() } label: {
                        row("导出日志", icon: "square.and.arrow.up")
                    }
                    row("下载设置", icon: "slider.horizontal.3")
                    row("屏蔽设置", icon: "eye.slash")
                }

                Section {
                    row("意见反馈", icon: "envelope")
                    row("服务协议", icon: "doc.text")
                    row("关于", icon: "info.circle")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("主菜单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .preferredColorScheme(scheme)
    }

    private func row(_ title: String, icon: String, tint: Color? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 22)
                .foregroundColor(tint ?? PXVRUITheme.sub(scheme))
            Text(title)
                .foregroundColor(tint ?? PXVRUITheme.text(scheme))
            Spacer()
        }
        .contentShape(Rectangle())
    }
}
