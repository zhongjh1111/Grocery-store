//
//  PXVRShare.swift
//  PXVRUI
//
//  直接用 UIKit 弹系统分享面板。
//  之前用 .sheet 嵌 .sheet 呈现 UIActivityViewController，
//  在 sheet 里再弹 sheet 常常静默失败，表现就是「点了导出没反应」。
//

import UIKit

enum PXVRShare {

    static func present(_ items: [Any]) {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let keyWindow = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first,
              let root = keyWindow.rootViewController else {
            return
        }

        var top = root
        while let presented = top.presentedViewController { top = presented }

        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let pop = vc.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY,
                                    width: 1, height: 1)
            pop.permittedArrowDirections = []
        }
        top.present(vc, animated: true)
    }
}
