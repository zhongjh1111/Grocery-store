//
//  PXVRMemberView.swift
//  PXVRUI
//
//  「我的大会员」——照原版截图一比一还原：
//    顶部横幅（原版 Fr.jpg）+ 左上返回 + 右下邮箱
//    圆形 logo（原版 B1.png）压在横幅左下角
//    右侧：续费/购买（蓝色实心）、退出登录（蓝框）、这是什么？
//    标题「我的大会员」+ 绿色到期徽章
//    「重要说明」可折叠卡片
//
//  文案取自原包 resources.arsc。
//

import SwiftUI
import UIKit

struct PXVRMemberView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: WebController

    @State private var email = PXVRKeychain.load().email
    @State private var password = PXVRKeychain.load().password
    @State private var isRegister = false
    @State private var showNote = true

    /// 服务端还没接，先占位
    private let expireText = "—"

    private let pageBG = Color(hex: 0xF5F5F5)
    private let green = Color(hex: 0x2E9E4F)
    private let buttonBlue = Color(hex: 0x1E88E5)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                banner
                identityRow
                if controller.isLoggedIn {
                    memberBlock
                } else {
                    loginBlock
                }
                Spacer(minLength: 30)
            }
        }
        .background(pageBG.ignoresSafeArea())
    }

    // MARK: 横幅

    private var banner: some View {
        ZStack {
            Image("pxvr_banner")
                .resizable()
                .scaledToFill()
                .frame(height: 235)
                .clipped()

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.25), radius: 3)
                    }
                    Spacer()
                }
                Spacer()
                HStack {
                    Spacer()
                    Text(controller.isLoggedIn ? email : "")
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.3), radius: 2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .frame(height: 235)
    }

    // MARK: 头像 + 右侧按钮

    private var identityRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image("pxvr_logo")
                .resizable()
                .frame(width: 88, height: 88)
                .clipShape(Circle())
                .overlay(Circle().stroke(.white, lineWidth: 3))
                .offset(y: -44)
                .padding(.leading, 14)

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 10) {
                    Button {
                        // 购买页待接
                    } label: {
                        Text("续费/购买")
                            .font(.system(size: 15))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(buttonBlue)
                            .cornerRadius(5)
                    }

                    if controller.isLoggedIn {
                        Button { controller.logout() } label: {
                            Text("退出登录")
                                .font(.system(size: 15))
                                .foregroundColor(buttonBlue)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color.white)
                                .overlay(RoundedRectangle(cornerRadius: 5)
                                    .stroke(buttonBlue, lineWidth: 1))
                        }
                    }
                }

                Text("这是什么?")
                    .font(.system(size: 12))
                    .foregroundColor(buttonBlue)
            }
            .padding(.top, 8)
            .padding(.trailing, 14)
        }
        .frame(height: 48)
    }

    // MARK: 已登录内容

    private var memberBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("我的大会员")
                .font(.system(size: 27, weight: .bold))
                .foregroundColor(.black)
                .padding(.horizontal, 16)

            Text("到期时间：\(expireText)")
                .font(.system(size: 13))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(green)
                .cornerRadius(4)
                .padding(.horizontal, 16)

            noteCard
                .padding(.horizontal, 14)
                .padding(.top, 6)
        }
    }

    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showNote.toggle() }
            } label: {
                HStack {
                    Text("重要说明")
                        .font(.system(size: 16))
                        .foregroundColor(.black)
                    Spacer()
                    Image(systemName: showNote ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13))
                        .foregroundColor(.black)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }

            if showNote {
                VStack(alignment: .leading, spacing: 14) {
                    Text("您正在浏览的是 PXVR 大会员，非 pixiv 高级会员。")
                    Text("但是呢 (^_^)，PXVR 大会员可以提供去除广告以及其他 pixiv 高级会员没有的功能~")
                }
                .font(.system(size: 15))
                .foregroundColor(Color(hex: 0x222222))
                .lineSpacing(7)
                .padding(.horizontal, 16)
                .padding(.bottom, 18)
            }
        }
        .background(Color.white)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: 0xE6E6E6), lineWidth: 0.7))
    }

    // MARK: 未登录内容

    private var loginBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isRegister ? "注册 PXVR 账号" : "登录 PXVR 账号")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.black)

            Text("未登录 PXVR 帐号并上线本设备。")
                .font(.system(size: 13))
                .foregroundColor(Color(hex: 0x777777))

            field("邮箱", text: $email, keyboard: .emailAddress)
            secure("密码", text: $password)

            HStack(spacing: 12) {
                Button {
                    PXVRKeychain.save(email: email, password: password)
                    controller.login(email: email, password: password,
                                     action: isRegister ? "r" : "l")
                } label: {
                    Text(isRegister ? "注册" : "登录")
                        .font(.system(size: 15))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(buttonBlue)
                        .cornerRadius(5)
                }
                Button { isRegister.toggle() } label: {
                    Text(isRegister ? "返回登录" : "注册")
                        .font(.system(size: 15))
                        .foregroundColor(buttonBlue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .stroke(buttonBlue, lineWidth: 1))
                }
            }

            if isRegister {
                Text("我们会将登录密码发送至您的邮箱")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: 0x777777))
            }
        }
        .padding(16)
        .background(Color.white)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: 0xE6E6E6), lineWidth: 0.7))
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    // MARK: 输入框

    private func field(_ title: String, text: Binding<String>,
                       keyboard: UIKeyboardType = .default) -> some View {
        TextField(title, text: text)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(11)
            .background(Color(hex: 0xFAFAFA))
            .cornerRadius(5)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(hex: 0xDDDDDD), lineWidth: 0.7))
    }

    private func secure(_ title: String, text: Binding<String>) -> some View {
        SecureField(title, text: text)
            .padding(11)
            .background(Color(hex: 0xFAFAFA))
            .cornerRadius(5)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(hex: 0xDDDDDD), lineWidth: 0.7))
    }
}
