//
//  Theme.swift
//  PXVRUI
//
//  配色直接取自原版 res/values/colors.xml，保证观感一致。
//

import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

enum PXVRTheme {

    // MARK: 原版色值

    /// Lightmode_colorPrimary
    static let lightPrimary = Color(hex: 0x0096FA)
    /// Lightmode_colorAccent / Nightmode_colorAccent
    static let accent = Color(hex: 0xFBB03B)
    /// Lightmode_toolbarTitleFontColor
    static let lightTitle = Color(hex: 0xFFFFFF)
    /// Lightmode_colorBackgroundDark
    static let lightBackground = Color(hex: 0xFAFAFA)
    /// Lightmode_colorCardViewBackground
    static let lightCard = Color(hex: 0xFFFFFF)
    /// Lightmode_colorLink
    static let lightLink = Color(hex: 0x0096FA)

    /// Nightmode_colorPrimary / colorCardViewBackground
    static let darkPrimary = Color(hex: 0x2B2B2B)
    /// Nightmode_colorPrimaryDark
    static let darkBackground = Color(hex: 0x3C3F41)
    /// Nightmode_toolbarTitleFontColor / fontColor
    static let darkTitle = Color(hex: 0xBABABA)
    /// Nightmode_iconColor
    static let darkIcon = Color(hex: 0x87939A)
    /// Nightmode_colorLink
    static let darkLink = Color(hex: 0x64B5F6)

    // MARK: 取色

    static func primary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? darkPrimary : lightPrimary
    }

    static func barTitle(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? darkTitle : lightTitle
    }

    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? darkBackground : lightBackground
    }

    static func card(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x2B2B2B) : lightCard
    }

    static func text(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? darkTitle : .black
    }

    static func icon(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? darkIcon : .white
    }

    static func link(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? darkLink : lightLink
    }
}
