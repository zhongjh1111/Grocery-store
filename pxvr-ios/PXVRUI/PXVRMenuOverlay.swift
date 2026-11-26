//
//  PXVRMenuOverlay.swift
//  PXVRUI
//
//  右上角溢出菜单。严格照原版实测结构：
//
//  一级（⋮）：
//    顶部图标行：书签 / 下载 / 主页 / 刷新
//    查看书签、浏览历史、下载管理器、高级搜索..、输入地址、
//    更多..、我的大会员、获取 PXVR NG、意见反馈、退出
//
//  二级（更多..）：
//    夜间模式 ☐、桌面版页面 ☑、启用数据同步 ☑、启动时恢复上次浏览页面 ☐、
//    屏蔽设置…、更多选项..、常见问题解答、pixiv 帮助、检查更新、关于
//    勾选框是橙色方框，开启时橙色实心带勾。
//

import SwiftUI

struct PXVRMenuOverlay: View {

    enum Level { case main, more }

    @Binding var level: Level

    // 一级动作
    let onBookmarks: () -> Void
    let onHistory: () -> Void
    let onDownloads: () -> Void
    let onAdvancedSearch: () -> Void
    let onInputAddress: () -> Void
    let onMember: () -> Void
    let onFeedback: () -> Void
    let onQuit: () -> Void

    // 二级动作
    @Binding var nightMode: Bool
    @Binding var desktopMode: Bool
    @Binding var dataSync: Bool
    @Binding var restoreLast: Bool
    let onMITM: () -> Void
    let onBlockSettings: () -> Void
    let onMoreOptions: () -> Void
    let onFAQ: () -> Void
    let onPixivHelp: () -> Void
    let onCheckUpdate: () -> Void
    let onAbout: () -> Void

    // 图标行
    let onHome: () -> Void
    let onReload: () -> Void

    private let orange = Color(hex: 0xFBB03B)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if level == .main {
                iconRow
                    .padding(.vertical, 6)
                divider
                mainItems
            } else {
                moreItems
            }
        }
        .frame(width: 214)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 10, x: -2, y: 6)
    }

    // MARK: 图标行

    private var iconRow: some View {
        HStack(spacing: 0) {
            iconButton("star", action: onBookmarks)
            iconButton("arrow.down.to.line", action: onDownloads)
            iconButton("house", action: onHome)
            iconButton("arrow.clockwise", action: onReload)
        }
    }

    private func iconButton(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 15))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(hex: 0xEEEEEE))
            .frame(height: 0.7)
    }

    // MARK: 一级菜单

    private var mainItems: some View {
        VStack(alignment: .leading, spacing: 0) {
            plainRow("查看书签", onBookmarks)
            plainRow("浏览历史", onHistory)
            plainRow("下载管理器", onDownloads)
            arrowRow("高级搜索..", onAdvancedSearch)
            plainRow("输入地址", onInputAddress)
            arrowRow("更多..") { level = .more }
            plainRow("我的大会员", onMember)
            plainRow("获取 PXVR NG", onMoreOptions)
            plainRow("意见反馈", onFeedback)
            plainRow("退出", onQuit)
        }
        .padding(.bottom, 4)
    }

    // MARK: 二级菜单

    private var moreItems: some View {
        VStack(alignment: .leading, spacing: 0) {
            checkRow("夜间模式", $nightMode)
            checkRow("桌面版页面", $desktopMode)
            checkRow("启用数据同步", $dataSync)
            checkRow("启动时恢复上次浏览页面", $restoreLast)
            plainRow("连接方式", onMITM)
            plainRow("屏蔽设置…", onBlockSettings)
            arrowRow("更多选项..", onMoreOptions)
            plainRow("常见问题解答", onFAQ)
            plainRow("pixiv 帮助", onPixivHelp)
            plainRow("检查更新", onCheckUpdate)
            plainRow("关于", onAbout)
        }
        .padding(.vertical, 2)
    }

    // MARK: 行

    private func plainRow(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
        }
    }

    private func arrowRow(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 15))
                    .foregroundColor(.black)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: 0x999999))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
    }

    private func checkRow(_ title: String, _ isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 15))
                    .foregroundColor(.black)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(isOn.wrappedValue ? orange : Color(hex: 0xBBBBBB), lineWidth: 1.4)
                        .frame(width: 17, height: 17)
                    if isOn.wrappedValue {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(orange)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
    }
}
