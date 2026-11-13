//
//  PXVRWebBridge.swift
//  PXVR-iOS
//
//  网页 ⇄ 原生的双向桥。
//
//  JS 侧命名沿用 `net.ngee.wv`（与原版保持一致，方便复用已有脚本片段）。
//  JS 调用 → JS 垫片把消息塞进 webkit.messageHandlers.pxvr → Swift 收
//  原生调用 → evaluateJavaScript 调 window.__pxvr.native(name, payload) → JS 侧分发器
//

import Foundation
import WebKit

/// 一条来自网页的消息
struct PXVRWebMessage {
    let name: String
    let args: [String: Any]
    /// 触发消息的页面地址，便于区分主框架 / iframe
    let url: String
}

protocol PXVRWebBridgeDelegate: AnyObject {
    func webBridge(_ bridge: PXVRWebBridge, didReceive message: PXVRWebMessage)
}

final class PXVRWebBridge: NSObject {

    /// 与 JS 侧约定的通道名
    static let handlerName = "pxvr"
    /// 暴露给网页的全局命名空间
    static let namespace = "net.ngee.wv"

    weak var webView: WKWebView?
    weak var delegate: PXVRWebBridgeDelegate?

    /// 最近一次收到的 ready 消息，用于避免重复初始化
    private(set) var isReady = false

    // MARK: - 安装

    /// 把桥装进配置。必须在创建 WKWebView 之前调用。
    func install(into configuration: WKWebViewConfiguration) {
        let ucc = WKUserContentController()
        ucc.add(self, name: Self.handlerName)

        // 越早注入越好：atDocumentStart 保证页面脚本运行前垫片已就位
        let script = WKUserScript(source: Self.bootstrapScript,
                                  injectionTime: .atDocumentStart,
                                  forMainFrameOnly: false)
        ucc.addUserScript(script)

        configuration.userContentController = ucc
    }

    // MARK: - 原生 → 网页

    /// 调用网页里的分发器。payload 必须能 JSON 序列化。
    func call(_ name: String, _ payload: [String: Any] = [:], completion: ((Any?) -> Void)? = nil) {
        guard let webView = webView else {
            PXVRLogger.warning("[bridge] webView 已释放，丢弃调用 \(name)")
            completion?(nil)
            return
        }
        let json = Self.jsonString(payload) ?? "{}"
        let js = "window.__pxvr && window.__pxvr.native(\(Self.jsString(name)), \(json));"
        webView.evaluateJavaScript(js) { result, error in
            if let error = error {
                PXVRLogger.warning("[bridge] 调用 \(name) 失败: \(error.localizedDescription)")
            }
            completion?(result)
        }
    }

    /// 往页面里注入一段任意脚本（调试、热修用）
    func evaluate(_ js: String, completion: ((Any?) -> Void)? = nil) {
        webView?.evaluateJavaScript(js) { result, error in
            if let error = error {
                PXVRLogger.warning("[bridge] evaluate 失败: \(error.localizedDescription)")
            }
            completion?(result)
        }
    }

    // MARK: - 工具

    private static func jsonString(_ obj: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    private static func jsString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    // MARK: - JS 垫片

    /// 注入到每个页面的启动脚本。
    /// 职责：
    ///   1. 建立 `net.ngee.wv` 命名空间，把调用转发给原生
    ///   2. 建立 `window.__pxvr.native()` 供原生回调
    ///   3. 兜住未捕获异常与控制台输出，回传给原生便于排查
    private static let bootstrapScript: String = """
    (function () {
      if (window.__pxvr && window.__pxvr.installed) { return; }

      var CHANNEL = "\(handlerName)";

      function post(name, args) {
        try {
          var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[CHANNEL];
          if (!h) { return false; }
          h.postMessage({ name: name, args: args || {}, url: String(location.href) });
          return true;
        } catch (e) { return false; }
      }

      // 原生 → 页面 的分发器
      var handlers = {};
      var api = {
        installed: true,
        version: 1,
        on: function (name, fn) { if (typeof fn === "function") { handlers[name] = fn; } return api; },
        native: function (name, payload) {
          var fn = handlers[name];
          if (typeof fn === "function") {
            try { return fn(payload); } catch (e) { post("error", { where: "handler:" + name, message: String(e) }); }
          }
          return null;
        },
        post: post
      };
      window.__pxvr = api;

      // 兼容命名空间：页面里可直接调 net.ngee.wv.xxx()
      var wv = window.net && window.net.ngee && window.net.ngee.wv ? window.net.ngee.wv : {};
      wv.bridge = api;
      wv.log = function () { post("log", { msg: Array.prototype.join.call(arguments, " ") }); };
      wv.toast = function (m) { post("toast", { msg: String(m) }); };
      wv.ready = function () { post("ready", { ua: navigator.userAgent, url: String(location.href) }); };
      wv.request = function (path, opts) {
        post("request", { path: String(path), opts: opts || {} });
      };
      window.net = window.net || {};
      window.net.ngee = window.net.ngee || {};
      window.net.ngee.wv = wv;

      // 错误回传
      window.addEventListener("error", function (ev) {
        post("error", { where: "window", message: String(ev.message || ""), source: String(ev.filename || "") });
      }, true);
      window.addEventListener("unhandledrejection", function (ev) {
        post("error", { where: "promise", message: String(ev.reason || "") });
      }, true);

      // SPA 路由变化（Pixiv 是单页应用，靠 pushState 切页）
      var push = history.pushState;
      history.pushState = function () {
        var r = push.apply(this, arguments);
        post("route", { url: String(location.href) });
        return r;
      };
      window.addEventListener("popstate", function () {
        post("route", { url: String(location.href) });
      });

      // DOM 就绪后再报一次，便于原生注入 UI
      document.addEventListener("DOMContentLoaded", function () { post("domready", {}); });
    })();
    """
}

// MARK: - WKScriptMessageHandler

extension PXVRWebBridge: WKScriptMessageHandler {

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == Self.handlerName else { return }

        let url = message.frameInfo.request.url?.absoluteString ?? ""
        var name = "unknown"
        var args: [String: Any] = [:]

        if let body = message.body as? [String: Any] {
            name = body["name"] as? String ?? "unknown"
            args = body["args"] as? [String: Any] ?? [:]
        } else if let text = message.body as? String, !text.isEmpty {
            // 兜底：页面直接 postMessage 了字符串
            name = "raw"
            args = ["text": text]
        }

        if name == "ready" { isReady = true }

        let msg = PXVRWebMessage(name: name, args: args, url: url)
        PXVRLogger.debug("[bridge] ← \(name) \(args.keys.sorted())")
        delegate?.webBridge(self, didReceive: msg)
    }
}
