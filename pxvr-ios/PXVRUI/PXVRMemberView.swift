//
//  PXVRMemberView.swift
//  PXVRUI
//
//  「我的大会员」页。结构与文案对照原包：
//    未登录：当前未开通 PXVR 大会员 / 未登录 PXVR 帐号并上线本设备。
//    已登录：到期时间：%s / 升级大会员套餐 / 设备管理器
//    设备管理器：可同时在线设备数：%1 / 切换当前在线设备次数：无限 /
//                当前剩余切换、修改新绑定设备数：%2 / 下线其他设备 / 启用设备
//
//  注：到期时间需要服务端接口，目前显示占位。
//

import SwiftUI
import UIKit

struct PXVRMemberView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: WebController

    @State private var email = PXVRKeychain.load().email
    @State private var password = PXVRKeychain.load().password
    @State private var isRegister = false

    /// 服务端下发前先占位
    private let expireText = "—"

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    accountCard
                    memberCard
                    if controller.isLoggedIn { deviceCard }
                }
                .padding(16)
            }
            .background(PXVRTheme.bg(scheme).ignoresSafeArea())
            .navigationTitle("我的大会员")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .preferredColorScheme(scheme)
    }

    // MARK: 账号

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(PXVRTheme.sub(scheme))
                VStack(alignment: .leading, spacing: 3) {
                    Text(controller.isLoggedIn ? email : "未登录帐号")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(PXVRTheme.text(scheme))
                    Text(controller.isLoggedIn ? "已登录" : "未登录 PXVR 帐号并上线本设备。")
                        .font(.system(size: 12))
                        .foregroundColor(PXVRTheme.sub(scheme))
                }
                Spacer()
            }

            if !controller.isLoggedIn {
                Divider().background(PXVRTheme.line(scheme))

                field("邮箱", text: $email, keyboard: .emailAddress)
                secureField("密码", text: $password)

                HStack(spacing: 12) {
                    Button {
                        PXVRKeychain.save(email: email, password: password)
                        controller.login(email: email, password: password,
                                         action: isRegister ? "r" : "l")
                    } label: {
                        Text(isRegister ? "注册" : "登录")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(PXVRTheme.accent)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                    Button {
                        isRegister.toggle()
                    } label: {
                        Text(isRegister ? "返回登录" : "注册")
                            .font(.system(size: 15))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(PXVRTheme.accent, lineWidth: 1)
                            )
                            .foregroundColor(PXVRTheme.accent)
                    }
                }

                if isRegister {
                    Text("我们会将登录密码发送至您的邮箱")
                        .font(.system(size: 11))
                        .foregroundColor(PXVRTheme.sub(scheme))
                }
            }
        }
        .padding(16)
        .background(PXVRTheme.card(scheme))
        .cornerRadius(12)
    }

    // MARK: 会员

    private var memberCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "crown.fill").foregroundColor(PXVRTheme.accent)
                Text("我的大会员")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(PXVRTheme.text(scheme))
                Spacer()
                Text(controller.isLoggedIn ? "已开通" : "当前未开通 PXVR 大会员")
                    .font(.system(size: 12))
                    .foregroundColor(controller.isLoggedIn ? PXVRTheme.online : PXVRTheme.sub(scheme))
            }

            if controller.isLoggedIn {
                Text("到期时间：\(expireText)")
                    .font(.system(size: 13))
                    .foregroundColor(PXVRTheme.sub(scheme))
            }

            Button {
                // 购买页待接
            } label: {
                Text("升级大会员套餐")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(PXVRTheme.accent)
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
        }
        .padding(16)
        .background(PXVRTheme.card(scheme))
        .cornerRadius(12)
    }

    // MARK: 设备管理

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("设备管理器")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(PXVRTheme.text(scheme))

            HStack(spacing: 6) {
                Circle().fill(PXVRTheme.online).frame(width: 7, height: 7)
                Text("当前设备在线")
                    .font(.system(size: 13))
                    .foregroundColor(PXVRTheme.text(scheme))
            }

            VStack(alignment: .leading, spacing: 6) {
                infoLine("可同时在线设备数：1")
                infoLine("切换当前在线设备次数：无限")
                infoLine("当前剩余切换、修改新绑定设备数：0")
            }

            HStack(spacing: 10) {
                smallButton("下线其他设备")
                smallButton("启用设备")
                smallButton("修改绑定邮箱")
            }

            Button {
                controller.logout()
            } label: {
                Text("退出登录")
                    .font(.system(size: 15))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(PXVRTheme.line(scheme)))
                    .foregroundColor(PXVRTheme.sub(scheme))
            }
        }
        .padding(16)
        .background(PXVRTheme.card(scheme))
        .cornerRadius(12)
    }

    // MARK: 小组件

    private func infoLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(PXVRTheme.sub(scheme))
    }

    private func smallButton(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(PXVRTheme.line(scheme)))
            .foregroundColor(PXVRTheme.text(scheme))
    }

    private func field(_ title: String, text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        TextField(title, text: text)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(11)
            .background(PXVRTheme.bg(scheme))
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(PXVRTheme.line(scheme)))
    }

    private func secureField(_ title: String, text: Binding<String>) -> some View {
        SecureField(title, text: text)
            .padding(11)
            .background(PXVRTheme.bg(scheme))
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(PXVRTheme.line(scheme)))
    }
}
