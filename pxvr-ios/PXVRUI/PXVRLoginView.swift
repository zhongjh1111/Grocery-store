//
//  PXVRLoginView.swift
//  PXVRUI
//
//  登录 / 注册页。照原版实测：
//    整屏横幅背景（同一张 Fr.jpg）
//    顶部问候语（按时段：Good morning / afternoon / evening）+「欢迎使用 PXVR」
//    两个下划线式输入框：邮箱、密码（占位文字白色）
//    居中两个按钮：注册（浅色）、登录（蓝色）
//    底部「忘记密码」
//

import SwiftUI
import UIKit

struct PXVRLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: WebController

    @State private var email = PXVRKeychain.load().email
    @State private var confirmReset = false
    @State private var hint = ""
    @State private var password = PXVRKeychain.load().password
    @State private var isRegister = false

    private let buttonBlue = Color(hex: 0x1E88E5)

    var body: some View {
        ZStack {
            // 整屏背景
            GeometryReader { geo in
                Image("pxvr_banner")
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: 70)

                Text(greeting)
                    .font(.system(size: 30, weight: .regular))
                    .foregroundColor(Color(hex: 0x1B1B1B))

                Text("欢迎使用 PXVR")
                    .font(.system(size: 15))
                    .foregroundColor(Color(hex: 0x2A2A2A))
                    .padding(.top, 6)

                Spacer()

                VStack(spacing: 22) {
                    underlineField("邮箱", text: $email, keyboard: .emailAddress)
                    underlineSecure("密码", text: $password)
                }
                .padding(.horizontal, 24)

                HStack(spacing: 18) {
                    Button { submit(register: true) } label: {
                        Text("注册")
                            .font(.system(size: 15))
                            .foregroundColor(Color(hex: 0x333333))
                            .frame(width: 110)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.85))
                            .cornerRadius(4)
                    }

                    Button { submit(register: false) } label: {
                        Text("登录")
                            .font(.system(size: 15))
                            .foregroundColor(.white)
                            .frame(width: 110)
                            .padding(.vertical, 8)
                            .background(buttonBlue)
                            .cornerRadius(4)
                    }
                }
                .padding(.top, 26)

                Button("忘记密码") {
                    guard !email.isEmpty else { hint = "请先填写邮箱"; return }
                    hint = ""
                    confirmReset = true
                }
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: 0x333333))
                    .padding(.top, 16)

                if !hint.isEmpty {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .padding(.top, 6)
                }

                Spacer().frame(height: 60)
            }
        }
        .alert("把登录密码发送到邮箱？", isPresented: $confirmReset) {
            Button("取消", role: .cancel) {}
            Button("发送") { controller.sendPassword(to: email); dismiss() }
        } message: {
            Text(email)
        }
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(Color(hex: 0x1B1B1B))
                    .padding(16)
            }
        }
        .statusBarHidden(false)
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12:  return "Good morning"
        case 12..<18: return "Good afternoon"
        default:      return "Good evening"
        }
    }

    private func submit(register: Bool) {
        guard !email.isEmpty, !password.isEmpty else { return }
        PXVRKeychain.save(email: email, password: password)
        controller.login(email: email, password: password, action: register ? "r" : "l")
        dismiss()
    }

    // MARK: 下划线输入框

    private func underlineField(_ title: String, text: Binding<String>,
                                keyboard: UIKeyboardType) -> some View {
        VStack(spacing: 6) {
            TextField("", text: text, prompt: Text(title).foregroundColor(.white))
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 15))
                .foregroundColor(.white)
                .padding(.vertical, 6)
            Rectangle()
                .fill(Color.white.opacity(0.85))
                .frame(height: 1)
        }
    }

    private func underlineSecure(_ title: String, text: Binding<String>) -> some View {
        VStack(spacing: 6) {
            SecureField("", text: text, prompt: Text(title).foregroundColor(.white))
                .font(.system(size: 15))
                .foregroundColor(.white)
                .padding(.vertical, 6)
            Rectangle()
                .fill(Color.white.opacity(0.85))
                .frame(height: 1)
        }
    }
}
