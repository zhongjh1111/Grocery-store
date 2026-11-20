//
//  PXVRLogView.swift
//  PXVRUI
//
//  日志弹窗（原版没有这个，调试用）。
//  以 sheet 形式弹出，可复制 / 导出 / 清空，正文可长按选中。
//

import SwiftUI
import UIKit

struct PXVRLogView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: WebController

    @State private var exportURL: URL?
    @State private var showExport = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(controller.logs.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .textSelection(.enabled)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(12)
                }
            }
            .navigationTitle("日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("清空") { controller.clearLogs() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        UIPasteboard.general.string = controller.logText
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                    Spacer()
                    Button {
                        exportURL = controller.exportLogURL()
                        if exportURL != nil { showExport = true }
                    } label: {
                        Label("导出", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .sheet(isPresented: $showExport) {
            if let u = exportURL { ActivityView(activityItems: [u]) }
        }
    }
}
