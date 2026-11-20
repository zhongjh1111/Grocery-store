//
//  PXVRUITheme.swift
//  PXVRUI
//
//  新 UI 的设计变量。颜色全部复用 Theme.swift（取自原版 colors.xml 的真实色值），
//  只补充原版主题里没有的几档灰阶。
//

import SwiftUI

enum PXVRUITheme {

    /// 主色（原版 Lightmode_colorPrimary #0096FA）
    static let accent = PXVRTheme.lightPrimary
    /// 原版 colorAccent #FBB03B，用于强调/角标
    static let highlight = Color(hex: 0xFBB03B)
    /// 在线绿点
    static let online = Color(hex: 0x2FB344)

    static func bg(_ s: ColorScheme) -> Color { PXVRTheme.background(s) }
    static func card(_ s: ColorScheme) -> Color { PXVRTheme.card(s) }
    static func text(_ s: ColorScheme) -> Color { PXVRTheme.text(s) }

    /// 次要文字
    static func sub(_ s: ColorScheme) -> Color {
        s == .dark ? Color(hex: 0x87939A) : Color(hex: 0x6B6B6B)
    }

    /// 分隔线
    static func line(_ s: ColorScheme) -> Color {
        s == .dark ? Color(hex: 0x3A3A3A) : Color(hex: 0xE2E2E2)
    }
}
