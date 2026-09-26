import Foundation
import AppKit
import WebKit
import Combine
import ChimeraCore

// MARK: - 标签(每标签独立 webview/历史/导航)

final class ReaderTab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate {
    let id = UUID()
    let document: AppModel.Document
    let webView: WKWebView
    weak var model: AppModel?

    @Published var history = CHMHistory()
    @Published var currentPath: String?
    @Published var navigationRequest: AppModel.NavigationRequest?
    /// 标签标题:当前页的章节名(TOC 优先,页面 <title> 次之,路径兜底)
    @Published var pageTitle = ""
    /// 搜索跳转后待高亮的检索词
    var pendingHighlight: String?

    private var cancellables = Set<AnyCancellable>()

    init(document: AppModel.Document, model: AppModel, loadPath: String?) {
        self.document = document
        self.model = model

        let container = document.container
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(CHMSchemeHandler(provider: { container }), forURLScheme: "chm")
        // 离线防线:屏蔽一切 http(s) 子资源(远程图片/脚本/字体等)。
        // 主框架导航由 decidePolicyFor 处理,这里只管子资源,与 PRD"无外部网络请求"对齐。
        // 异步安装,不阻塞标签创建(规则按 identifier 持久化,二次启动走缓存);
        // 首次安装完成前初次加载会被积压到规则就绪(见 load),后续标签直接放行
        Self.installOfflineRules(into: config.userContentController)
        webView = WKWebView(frame: .zero, configuration: config)

        super.init()
        webView.navigationDelegate = self

        // 本标签导航请求
        $navigationRequest
            .receive(on: DispatchQueue.main)
            .sink { [weak self] req in
                guard let self, let req else { return }
                self.load(path: req.path)
            }
            .store(in: &cancellables)

        // 页内查找(仅作用于活动标签)
        model.$findAction
            .receive(on: DispatchQueue.main)
            .sink { [weak self] act in
                guard let self, let act,
                      self.model?.activeTabID == self.id else { return }
                self.webView.evaluateJavaScript(Self.findJS(act.query, direction: act.direction)) { result, _ in
                    guard let status = result as? String else { return }
                    model.findStatus = status
                    if ProcessInfo.processInfo.environment["CHIMERA_SMOKE"] == "1",
                       ProcessInfo.processInfo.environment["CHIMERA_FIND"] == act.query {
                        print("FIND q=\(act.query) status=\(status)")
                        exit(status.hasPrefix("0/") ? 1 : 0)
                    }
                }
            }
            .store(in: &cancellables)

        load(path: loadPath ?? document.homePath)
    }

    func requestNav(_ local: String) {
        guard !local.isEmpty else { return }
        navigationRequest = AppModel.NavigationRequest(path: local)
    }

    func goBack() {
        if let p = history.goBack() { requestNav(p) }
    }

    func goForward() {
        if let p = history.goForward() { requestNav(p) }
    }

    // MARK: 离线拦截规则(进程级一次性)

    /// 规则安装是否已了结(就绪或失败放行);仅主线程读写。
    /// 首个 webView.load 必须等它置位,防止规则编译完成前首个页面已发出、
    /// 外部 http(s) 子资源漏网(违反 PRD"无外部网络请求")。
    private static var offlineRulesSettled = false
    private static var offlineRulesInstallStarted = false
    /// 规则就绪前积压的待执行加载(仅规则就绪前创建的标签初次加载会走这里)。
    private static var offlineRulesWaiters: [() -> Void] = []

    /// 编译/读取持久化的内容拦截规则(屏蔽 http/https 子资源)。
    /// 全程异步:编译结果按 identifier 持久化,二次启动 lookUp 直接命中缓存;
    /// 规则可在 WebView 创建后追加到同一个 userContentController。
    /// 首次安装(进程级)无论成功失败都结束等待——查找/编译失败放行并打日志,
    /// 绝不能卡死启动。
    private static func installOfflineRules(into ucc: WKUserContentController) {
        let isFirst = !offlineRulesInstallStarted   // 主线程调用(标签创建)
        offlineRulesInstallStarted = true
        let settleIfFirst: (String?) -> Void = { failure in
            if isFirst { Self.settleOfflineRules(failure) }
        }
        guard let store = WKContentRuleListStore.default() else {
            settleIfFirst("WKContentRuleListStore.default() 不可用")
            return
        }
        let id = "chimera-block-external-subresources"
        store.lookUpContentRuleList(forIdentifier: id) { list, _ in
            DispatchQueue.main.async {
                if let list {
                    ucc.add(list)
                    settleIfFirst(nil)
                    return
                }
                let json = #"[{"trigger":{"url-filter":"^https?://","resource-type":["image","script","style-sheet","font","media","svg-document","raw","popup","ping","fetch","websocket","other"]},"action":{"type":"block"}}]"#
                store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) { list, error in
                    DispatchQueue.main.async {
                        if let list { ucc.add(list) }
                        settleIfFirst(list == nil
                                      ? "规则编译失败: \(error.map { String(describing: $0) } ?? "-")"
                                      : nil)
                    }
                }
            }
        }
    }

    /// 结束等待:失败记一行日志后照常放行,并触发全部积压的初次加载。
    private static func settleOfflineRules(_ failure: String?) {
        if let failure { print("离线拦截规则未安装,放行加载: \(failure)") }
        offlineRulesSettled = true
        let waiters = offlineRulesWaiters
        offlineRulesWaiters.removeAll()
        waiters.forEach { $0() }
    }

    private func load(path rawPath: String, fragment: String? = nil) {
        let path = rawPath.hasPrefix("/") ? rawPath : "/" + rawPath
        let perform = { [weak self] in
            guard let self else { return }
            var comps = URLComponents()
            comps.scheme = "chm"
            comps.host = "doc"
            comps.path = path
            comps.fragment = fragment
            if let u = comps.url {
                self.webView.load(URLRequest(url: u))
            }
        }
        // 离线规则就绪(或失败放行)前积压加载,避免首开竞态;
        // 后续标签创建时规则多半已就绪,直接放行
        if Self.offlineRulesSettled {
            perform()
        } else {
            Self.offlineRulesWaiters.append(perform)
        }
    }

    // MARK: WKNavigationDelegate

    /// 导航策略(离线/隐私):只允许 chm: 在 WebView 内加载;
    /// 用户点击的 http(s) 链接取消并转外部浏览器;iframe/重定向等静默取消;
    /// ms-its 等其他 scheme 一律取消;target=_blank(targetFrame == nil)的
    /// chm 链接改在当前 WebView 加载。
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url,
              let scheme = url.scheme?.lowercased() else {
            decisionHandler(.cancel)
            return
        }
        switch scheme {
        case "chm":
            if navigationAction.modifierFlags.contains(.command) {
                // ⌘+点击:在新标签页打开
                decisionHandler(.cancel)
                model?.openInNewTab(url.path)
            } else if navigationAction.targetFrame == nil {
                decisionHandler(.cancel)
                webView.load(URLRequest(url: url))
            } else {
                decisionHandler(.allow)
            }
        case "http", "https":
            // 仅用户真实点击链接才转外部浏览器;iframe/重定向等静默取消
            if navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        default:
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let url = webView.url, url.scheme?.lowercased() == "chm" {
            currentPath = url.path
            history.push(url.path)
            updatePageTitle()
            model?.tabDidCommitPath(url.path, bookURL: document.url)
        }
    }

    /// 标签标题:TOC 章节名优先,页面 <title> 兜底,最后退到文件名。
    private func updatePageTitle() {
        guard let path = currentPath else { return }
        if let t = model?.tocTitleMap[path] ?? model?.tocTitleMap[String(path.dropFirst())],
           !t.isEmpty {
            pageTitle = t
            return
        }
        let docTitle = webView.title ?? ""
        pageTitle = docTitle.isEmpty ? (path as NSString).lastPathComponent : docTitle
    }

    /// 目录异步解析完成后由模型调用:以刚就绪的 TOC 标题重刷标签标题
    /// (异步打开时首屏标题先以 <title>/路径兜底)。
    func refreshTitle() { updatePageTitle() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let smoke = ProcessInfo.processInfo.environment["CHIMERA_SMOKE"] == "1"
        updatePageTitle()   // didCommit 时 <title> 尚未解析,此处再刷一次
        if let q = pendingHighlight {
            pendingHighlight = nil
            webView.evaluateJavaScript(Self.highlightJS(q)) { result, _ in
                if smoke { print("HIGHLIGHT count=\((result as? Int) ?? 0)") }
            }
        }
        if let m = model { applyFont(m.settings) }
        if smoke {
            // 强断言:contentType 必须是 text/html 且正文非空——把源码当文本显示时此处返回 -1
            webView.evaluateJavaScript(
                "(document.contentType && document.contentType.indexOf('text/html')===0 "
                + "&& document.body && document.body.innerText.length>0) "
                + "? document.body.innerText.length : -1"
            ) { r, _ in
                self.model?.tabDidFinish(self, textLen: (r as? Int) ?? -1)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if ProcessInfo.processInfo.environment["CHIMERA_SMOKE"] == "1" {
            print("SMOKE FAIL load: \(error)")
            exit(1)
        }
    }

    // MARK: 注入 JS

    func applyFont(_ s: CHMDisplaySettings) {
        webView.evaluateJavaScript(Self.fontJS(s), completionHandler: nil)
    }

    /// 任意字符串 → 合法 JS 字符串字面量(JSON 编码结果是 JS 字面量的子集,
    /// 引号/反斜杠/控制字符均被可靠转义)。
    static func jsStringLiteral(_ s: String) -> String {
        if let data = try? JSONEncoder().encode(s),
           let lit = String(data: data, encoding: .utf8) {
            return lit
        }
        return "\"\""
    }

    /// 用户字体注入(每次页面加载与设置变更时应用)。
    /// font-family 全局覆盖;font-size 只作用于 body,保留 h1/h2 等标题的相对层级。
    static func fontJS(_ s: CHMDisplaySettings) -> String {
        let fam = s.fontFamily.map { jsStringLiteral($0) + "," } ?? ""
        return """
        (function(){var e=document.getElementById('chimera-font-style');
        if(!e){e=document.createElement('style');e.id='chimera-font-style';document.head.appendChild(e);}
        e.textContent='*{font-family:\(fam)-apple-system,system-ui,sans-serif !important;}body{font-size:\(Int(s.fontSize))px !important;}';
        return 1;})()
        """
    }

    /// 命中词高亮:文本节点包裹 <mark> 并滚动到首个命中。
    /// 查询词小写化(ql)在循环外一次完成,对齐 findJS 的做法。
    static func highlightJS(_ query: String) -> String {
        return """
        (function(){
          var q=\(jsStringLiteral(query)); if(!q) return 0;
          var ql=q.toLowerCase();
          var count=0;
          var walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);
          var nodes=[]; while(walker.nextNode()) nodes.push(walker.currentNode);
          nodes.forEach(function(n){
            var t=n.nodeValue; if(!t) return;
            var lt=t.toLowerCase(); var i=lt.indexOf(ql); if(i<0) return;
            var frag=document.createDocumentFragment(); var pos=0;
            while(i>=0){
              frag.appendChild(document.createTextNode(t.slice(pos,i)));
              var m=document.createElement('mark');
              m.style.backgroundColor='#ffe066'; m.style.color='inherit';
              m.textContent=t.substring(i,i+q.length);
              frag.appendChild(m); count++;
              pos=i+q.length; i=lt.indexOf(ql,pos);
            }
            frag.appendChild(document.createTextNode(t.slice(pos)));
            n.parentNode.replaceChild(frag,n);
          });
          var f=document.querySelector('mark');
          if(f) f.scrollIntoView({block:'center'});
          return count;
        })()
        """
    }

    /// 页内查找 JS:收集全部命中(span 包裹),游标循环,当前项橙色并滚动。
    static func findJS(_ query: String, direction: Int) -> String {
        return """
        (function(){
          var q=\(jsStringLiteral(query)); if(!q) return '0/0';
          var dir=\(direction);
          if(dir===0 || window.__chimeraFindQ!==q || !window.__chimeraMarks){
            if(window.__chimeraMarks){
              window.__chimeraMarks.forEach(function(m){
                if(m.parentNode){ var p=m.parentNode; p.replaceChild(document.createTextNode(m.textContent),m); p.normalize(); }
              });
            }
            window.__chimeraFindQ=q; window.__chimeraMarks=[]; window.__chimeraIdx=-1;
            var ql=q.toLowerCase();
            var walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);
            var nodes=[]; while(walker.nextNode()) nodes.push(walker.currentNode);
            nodes.forEach(function(n){
              var t=n.nodeValue; if(!t) return;
              var lt=t.toLowerCase(); var i=lt.indexOf(ql); if(i<0) return;
              var frag=document.createDocumentFragment(); var pos=0;
              while(i>=0){
                frag.appendChild(document.createTextNode(t.slice(pos,i)));
                var m=document.createElement('span');
                m.style.backgroundColor='#ffe066';
                m.textContent=t.substr(i,q.length);
                window.__chimeraMarks.push(m);
                frag.appendChild(m);
                pos=i+q.length; i=lt.indexOf(ql,pos);
              }
              frag.appendChild(document.createTextNode(t.slice(pos)));
              n.parentNode.replaceChild(frag,n);
            });
          }
          var marks=window.__chimeraMarks||[];
          if(!marks.length) return '0/0';
          if(window.__chimeraIdx>=0 && marks[window.__chimeraIdx])
            marks[window.__chimeraIdx].style.backgroundColor='#ffe066';
          window.__chimeraIdx += (dir===0 ? (window.__chimeraIdx<0?1:0) : dir);
          if(window.__chimeraIdx>=marks.length) window.__chimeraIdx=0;
          if(window.__chimeraIdx<0) window.__chimeraIdx=marks.length-1;
          var m=marks[window.__chimeraIdx];
          m.style.backgroundColor='#ff9500';
          m.scrollIntoView({block:'center'});
          return (window.__chimeraIdx+1)+'/'+marks.length;
        })()
        """
    }
}
