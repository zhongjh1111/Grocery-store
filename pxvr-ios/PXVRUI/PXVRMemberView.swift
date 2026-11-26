//
//  PXVRMemberView.swift
//  PXVRUI
//
//  「我的大会员」——按模拟器实测还原（1920×1080）：
//
//    横幅 235pt 高，左上返回，右下邮箱 /「未登录帐号」
//    圆形 logo 半压横幅左下
//    横幅下方右侧：续费/购买（蓝实心）+ 退出登录/登录注册（蓝框）；下面「这是什么？」
//    「我的大会员」27pt 粗体
//    徽章：已登录「到期时间：…」绿色；未登录「未开通」
//    未登录时多一行「我的大会员不见了？」链接
//    「重要说明」卡片
//

import SwiftUI
import UIKit

struct PXVRMemberView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: WebController

    @State private var email = PXVRKeychain.load().email
    @State private var showNote = true
    @State private var showLogin = false
    @State private var didLoad = false

    private var expireText: String {
        controller.premiumExpire.isEmpty ? "—" : controller.premiumExpire
    }
    private let green = Color(hex: 0x2E9E4F)
    private let buttonBlue = Color(hex: 0x1E88E5)

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    banner
                    avatarRow
                    actionRow
                    titleRow
                    badgeRow
                    if !controller.isLoggedIn {
                        Button("我的大会员不见了？") { }
                            .font(.system(size: 13))
                            .foregroundColor(buttonBlue)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                    }
                    purchasesCard
                        .padding(.horizontal, 14)
                        .padding(.top, 12)

                    deviceCard
                        .padding(.horizontal, 14)
                        .padding(.top, 12)

                    noteCard
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                    Spacer(minLength: 24)
                }
            }
        }
        .sheet(isPresented: $showLogin) {
            PXVRLoginView(controller: controller)
        }
        .onAppear {
            guard !didLoad, controller.isLoggedIn else { return }
            didLoad = true
            controller.loadDevices()
            controller.loadPurchases()
        }
    }

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
                            .shadow(color: .black.opacity(0.3), radius: 3)
                    }
                    Spacer()
                }
                Spacer()
                HStack {
                    Spacer()
                    Text(controller.isLoggedIn ? email : "未登录帐号")
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.35), radius: 2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .frame(height: 235)
    }

    private var avatarRow: some View {
        HStack {
            Image("pxvr_logo")
                .resizable()
                .frame(width: 88, height: 88)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white, lineWidth: 3))
                .offset(y: -44)
                .padding(.leading, 16)
            Spacer()
        }
        .frame(height: 44)
    }

    private var actionRow: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 10) {
                Button { } label: {
                    Text("续费/购买")
                        .font(.system(size: 15))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background(buttonBlue)
                        .cornerRadius(4)
                }
                if controller.isLoggedIn {
                    Button { controller.logout() } label: {
                        Text("退出登录")
                            .font(.system(size: 15))
                            .foregroundColor(buttonBlue)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(Color.white)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(buttonBlue, lineWidth: 1))
                    }
                } else {
                    Button { showLogin = true } label: {
                        Text("登录/注册")
                            .font(.system(size: 15))
                            .foregroundColor(buttonBlue)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(Color.white)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(buttonBlue, lineWidth: 1))
                    }
                }
            }
            Text("这是什么？")
                .font(.system(size: 12))
                .foregroundColor(buttonBlue)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 16)
        .padding(.top, -26)
    }

    private var titleRow: some View {
        Text("我的大会员")
            .font(.system(size: 27, weight: .bold))
            .foregroundColor(.black)
            .padding(.horizontal, 16)
            .padding(.top, 14)
    }

    private var badgeRow: some View {
        Group {
            if controller.isLoggedIn {
                Text("到期时间：\(expireText)")
                    .foregroundColor(.white)
                    .background(green)
            } else {
                Text("未开通")
                    .foregroundColor(.black)
                    .background(Color(hex: 0xF0F0F0))
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .cornerRadius(3)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - 购买记录

    private var purchasesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("购买记录")
                    .font(.system(size: 16))
                    .foregroundColor(.black)
                Spacer()
                Text("\(controller.purchases.count) 笔")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            if controller.purchases.isEmpty {
                Text(controller.isLoggedIn ? "暂无记录" : "请先登录")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            } else {
                ForEach(Array(controller.purchases.enumerated()), id: \.offset) { _, item in
                    Divider().padding(.horizontal, 16)
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(txTitle(item)).font(.system(size: 13))
                            Text(txTime(item)).font(.system(size: 11)).foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(txState(item))
                            .font(.system(size: 11))
                            .foregroundColor(txState(item) == "已支付" ? green : .secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                }
            }
        }
        .background(Color.white)
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(hex: 0xE8E8E8), lineWidth: 0.8))
    }

    private func txTitle(_ d: [String: Any]) -> String {
        if let add = d["tadd"] as? Int, add != 0 {
            return add > 0 ? "活动赠送 \(add / 86400) 天" : "扣减 \((-add) / 86400) 天"
        }
        if let sec = d["membership_seconds"] as? Int, sec > 0 {
            return "\(sec / 86400) 天会员"
        }
        return "会员订单"
    }

    private func txTime(_ d: [String: Any]) -> String {
        guard let pt = d["pt"] as? Int, pt > 946_684_800 else { return "" }
        let f = DateFormatter()
        f.dateFormat = "yyyy年M月d日 HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(pt)))
    }

    private func txState(_ d: [String: Any]) -> String {
        switch d["stat"] as? Int {
        case 1: return "已支付"
        case 2: return "已退款"
        default: return "处理中"
        }
    }

    // MARK: - 设备管理

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("设备管理").font(.system(size: 16)).foregroundColor(.black)
                Spacer()
                Button("刷新") { controller.loadDevices() }
                    .font(.system(size: 12)).foregroundColor(buttonBlue)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)

            if controller.devices.isEmpty {
                Text(controller.isLoggedIn ? "暂无设备" : "请先登录")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                    .padding(.horizontal, 16).padding(.bottom, 14)
            } else {
                ForEach(Array(controller.devices.enumerated()), id: \.offset) { idx, dev in
                    Divider().padding(.horizontal, 16)
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(deviceName(dev)).font(.system(size: 13))
                            Text(deviceTime(dev)).font(.system(size: 11)).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("操作") { controller.operateDevice(idx) }
                            .font(.system(size: 11))
                            .foregroundColor(buttonBlue)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 9)
                }
            }

            Text("可同时在线设备数以服务端为准")
                .font(.system(size: 10)).foregroundColor(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(Color.white)
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(hex: 0xE8E8E8), lineWidth: 0.8))
    }

    private func deviceName(_ d: [String: Any]) -> String {
        for k in ["n", "name", "m", "model", "dn", "t"] {
            if let v = d[k] as? String, !v.isEmpty, v != "重要说明" { return v }
        }
        return "未知设备"
    }

    private func deviceTime(_ d: [String: Any]) -> String {
        for k in ["t", "time", "ctime", "pt", "d"] {
            if let v = d[k] as? Int {
                let sec = v > 1_000_000_000 ? v : v / 1000
                guard sec > 946_684_800, sec < 4_102_444_800 else { continue }
                let f = DateFormatter(); f.dateFormat = "yyyy年M月d日 HH:mm"
                return f.string(from: Date(timeIntervalSince1970: TimeInterval(sec)))
            }
        }
        return ""
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
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(hex: 0xE8E8E8), lineWidth: 0.8))
    }
}
