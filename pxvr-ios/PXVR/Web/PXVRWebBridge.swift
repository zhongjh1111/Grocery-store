//
//  PXVRWebBridge.swift
//  PXVR-iOS
//
//  网页 ⇄ 原生 的双向桥。
//
//  命名规则：JS 侧挂在 `window.Sensei`（老师）下，方法名用学生名表达语义。
//  **接口形态是回调式**——iOS 的 WKWebView 没有 addJavascriptInterface 那种同步返回，
//  所有取值都必须走 Promise。
//
//  JS 侧用法：
//      const s = await Sensei.arona("feedback_title");
//      Sensei.serika("https://example.com");
//      const n = await Sensei.shiroko();
//

import Foundation
import UIKit
import WebKit

// MARK: - 能力表

/// 一一对应原版的 11 个 @JavascriptInterface 方法，改用学生名表达语义。
enum PXVRNativeAPI: String, CaseIterable {
    /// 阿罗娜：查资料 → 取文案/配置。参数 key
    case arona
    /// 优香：算数值 → 屏幕缩放百分比
    case yuuka
    /// 白子：列清单 → 取下载/收藏列表
    case shiroko
    /// 爱丽丝：处理素材 → 选图并做解码/缩放/哈希
    case aris
    /// 星野：切状态 → UI 切换
    case hoshino
    /// 芹香：跑腿 → 打开外部链接
    case serika
    /// 普拉娜：备份/副官 → 打开内置页面
    case plana
    /// 未花：门面 → 应用图标
    case mika
    /// 宁瑠：干活一号 → 主线程动作
    case neru
    /// 卡琳：干活二号 → 主线程动作
    case karin
    /// 日奈：值守 → 版本/环境信息
    case hina
}

/// 一条来自网页的调用
struct PXVRWebCall {
    let api: PXVRNativeAPI
    let args: [String: Any]
    /// 回注用的编号
    let callbackID: Int
    let url: String
}

protocol PXVRWebBridgeDelegate: AnyObject {
    /// 处理桥自己实现不了的能力。实现方必须调用 reply（可传 nil）。
    func webBridge(_ bridge: PXVRWebBridge,
                   perform call: PXVRWebCall,
                   reply: @escaping (Any?) -> Void)
}

// MARK: - 桥

final class PXVRWebBridge: NSObject {

    /// 与 JS 侧约定的消息通道名
    static let handlerName = "sensei"
    /// JS 全局命名空间
    static let namespace = "Sensei"

    weak var webView: WKWebView?
    weak var delegate: PXVRWebBridgeDelegate?

    private(set) var isReady = false

    /// arona(key) 的本地兜底文案
    private let strings: [String: String]

    init(strings: [String: String] = [:]) {
        self.strings = strings
        super.init()
    }

    // MARK: 安装

    /// 必须在创建 WKWebView 之前调用。
    func install(into configuration: WKWebViewConfiguration) {
        let ucc = WKUserContentController()
        ucc.add(self, name: Self.handlerName)
        ucc.addUserScript(WKUserScript(source: Self.bootstrapScript,
                                       injectionTime: .atDocumentStart,
                                       forMainFrameOnly: false))
        configuration.userContentController = ucc
    }

    // MARK: 原生 → 网页

    /// 在页面里求值
    func evaluate(_ js: String, completion: ((Any?) -> Void)? = nil) {
        webView?.evaluateJavaScript(js) { result, error in
            if let error = error {
                PXVRLogger.warning("[bridge] evaluate 失败: \(error.localizedDescription)")
            }
            completion?(result)
        }
    }

    /// 主动推事件给页面：Sensei.on("名字", cb) 接收
    func push(_ event: String, _ payload: [String: Any] = [:]) {
        let json = Self.json(payload) ?? "{}"
        evaluate("window.Sensei && window.Sensei.__emit(\(Self.jsString(event)), \(json));")
    }

    // MARK: 内部

    private func reply(_ id: Int, _ value: Any?) {
        let body: String
        if let dict = value as? [String: Any] {
            body = Self.json(["v": dict]) ?? "{\"v\":null}"
        } else if let s = value as? String {
            body = Self.json(["v": s]) ?? "{}"
        } else if let n = value as? NSNumber {
            body = "{\"v\":\(n)}"
        } else if let arr = value as? [Any], JSONSerialization.isValidJSONObject(["v": arr]) {
            body = Self.json(["v": arr]) ?? "{}"
        } else {
            body = "{\"v\":null}"
        }
        evaluate("window.Sensei && window.Sensei.__reply(\(id), \(body));")
    }

    /// 桥自己能答的先答，答不了的转给 delegate
    private func dispatch(_ call: PXVRWebCall) {
        switch call.api {
        case .arona:
            let key = call.args["key"] as? String ?? ""
            reply(call.callbackID, strings[key])

        case .yuuka:
            let pct = Int((UIScreen.main.scale * 100).rounded())
            reply(call.callbackID, "\(pct)%")

        case .hina:
            let info: [String: Any] = [
                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
                "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0",
                "system": UIDevice.current.systemVersion,
                "model": UIDevice.current.model
            ]
            reply(call.callbackID, info)

        case .mika:
            reply(call.callbackID, Self.appIconBase64())

        default:
            if let d = delegate {
                d.webBridge(self, perform: call) { [weak self] value in
                    self?.reply(call.callbackID, value)
                }
            } else {
                PXVRLogger.warning("[bridge] \(call.api.rawValue) 无接收方，回 null")
                reply(call.callbackID, nil)
            }
        }
    }

    private static func appIconBase64() -> String? {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let name = files.last,
              let image = UIImage(named: name),
              let data = image.pngData() else { return nil }
        return data.base64EncodedString()
    }

    static func json(_ obj: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    static func jsString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    // MARK: JS 垫片

    private static let bootstrapScript: String = """
    (function () {
      if (window.Sensei && window.Sensei.__installed) { return; }

      var CHANNEL = "\(handlerName)";
      var seq = 0;
      var pending = {};
      var listeners = {};

      function post(name, args, id) {
        try {
          var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[CHANNEL];
          if (!h) { return false; }
          h.postMessage({ name: name, args: args || {}, id: id || 0, url: String(location.href) });
          return true;
        } catch (e) { return false; }
      }

      function call(name, args) {
        return new Promise(function (resolve, reject) {
          var id = ++seq;
          pending[id] = { resolve: resolve, reject: reject };
          if (!post(name, args, id)) {
            delete pending[id];
            reject(new Error("bridge unavailable"));
            return;
          }
          setTimeout(function () {
            if (pending[id]) { delete pending[id]; reject(new Error("timeout: " + name)); }
          }, 15000);
        });
      }

      var S = {
        __installed: true,
        version: 1,

        __reply: function (id, body) {
          var p = pending[id];
          if (!p) { return; }
          delete pending[id];
          p.resolve(body ? body.v : null);
        },

        __emit: function (event, payload) {
          var list = listeners[event];
          if (!list) { return; }
          for (var i = 0; i < list.length; i++) {
            try { list[i](payload); } catch (e) {}
          }
        },

        on: function (event, fn) {
          (listeners[event] = listeners[event] || []).push(fn);
          return S;
        },

        // ---- 学生名 → 能力 ----
        arona:   function (key)       { return call("arona",   { key: String(key) }); },
        yuuka:   function ()          { return call("yuuka",   {}); },
        shiroko: function ()          { return call("shiroko", {}); },
        aris:    function (opts)      { return call("aris",    opts || {}); },
        hoshino: function (state)     { return call("hoshino", { state: (state === undefined ? null : state) }); },
        serika:  function (url)       { return call("serika",  { url: String(url) }); },
        plana:   function (page)      { return call("plana",   { page: String(page) }); },
        mika:    function ()          { return call("mika",    {}); },
        neru:    function (action, a) { return call("neru",    { action: String(action), args: a || {} }); },
        karin:   function (action, a) { return call("karin",   { action: String(action), args: a || {} }); },
        hina:    function ()          { return call("hina",    {}); }
      };

      window.Sensei = S;

      // 路由变化推给页面（Pixiv 是单页应用）
      var push = history.pushState;
      history.pushState = function () {
        var r = push.apply(this, arguments);
        S.__emit("route", { url: String(location.href) });
        return r;
      };
      window.addEventListener("popstate", function () {
        S.__emit("route", { url: String(location.href) });
      });
    })();
    """
}

// MARK: - 收消息

extension PXVRWebBridge: WKScriptMessageHandler {

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == Self.handlerName else { return }

        let url = message.frameInfo.request.url?.absoluteString ?? ""
        guard let body = message.body as? [String: Any],
              let raw = body["name"] as? String,
              let api = PXVRNativeAPI(rawValue: raw) else {
            PXVRLogger.warning("[bridge] 未知调用")
            return
        }

        let args = body["args"] as? [String: Any] ?? [:]
        let id = body["id"] as? Int ?? 0

        dispatch(PXVRWebCall(api: api, args: args, callbackID: id, url: url))
    }
}
