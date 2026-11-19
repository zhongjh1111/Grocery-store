//
//  PXVRTheme.swift
//  PXVRUI
//
//  配色取自原版 APK 的界面观感：
//    白底 / 黑字 / pixiv 蓝作强调色 / 灰色说明文字 / 绿色在线点
//  文案全部来自原包 resources.arsc 里的真实字符串。
//

import SwiftUI

enum PXVRTheme {

    /// pixiv 品牌蓝
    static let accent = Color(red: 0.0, green: 0.588, blue: 0.980)   // #0096FA
    /// 在线绿点
    static let online = Color(red: 0.20, green: 0.72, blue: 0.35)

    static func bg(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.07, green: 0.07, blue: 0.08) : .white
    }
    static func card(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.13, green: 0.13, blue: 0.14) : Color(red: 0.97, green: 0.97, blue: 0.98)
    }
    static func text(_ s: ColorScheme) -> Color {
        s == .dark ? .white : .black
    }
    static func sub(_ s: ColorScheme) -> Color {
        s == .dark ? Color(white: 0.62) : Color(white: 0.42)
    }
    static func line(_ s: ColorScheme) -> Color {
        s == .dark ? Color(white: 0.22) : Color(white: 0.88)
    }
}
