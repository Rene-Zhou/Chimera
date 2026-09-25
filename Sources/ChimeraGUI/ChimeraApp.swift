import SwiftUI
import AppKit
import WebKit
import Combine
import UniformTypeIdentifiers
import ChimeraCore

@main
struct ChimeraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Chimera") {
            ReaderView(model: model)
                .frame(minWidth: 820, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开…") { model.openPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("新建标签页") { model.newTab() }
                    .keyboardShortcut("t", modifiers: .command)
                    .disabled(model.tabs.isEmpty)
                Button("关闭标签页") { model.closeActiveTab() }
                    .keyboardShortcut("w", modifiers: .command)
                    .disabled(model.tabs.isEmpty)
                Divider()
                Button("放大") { model.zoom(delta: 0.1) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("缩小") { model.zoom(delta: -0.1) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("实际大小") { model.zoom(reset: true) }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
                Button("显示设置…") { model.settingsVisible = true }
                if !model.recents.isEmpty {
                    Menu("最近打开") {
                        ForEach(model.recents, id: \.self) { p in
                            Button(URL(fileURLWithPath: p).lastPathComponent) {
                                model.open(url: URL(fileURLWithPath: p))
                            }
                        }
                    }
                }
            }
            CommandGroup(after: .textEditing) {
                Button("页内查找…") { model.findVisible = true }
                    .keyboardShortcut("f", modifiers: .command)
            }
        }
    }
}

// MARK: - 文档模型

/// Finder 双击/拖到 Dock 图标时经打开事件进入。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls where u.pathExtension.lowercased() == "chm" {
            AppModel.shared?.open(url: u)
            return
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    struct Document {
        let id = UUID()
        let url: URL
        let container: CHMContainer
        let homePath: String
        let toc: [CHMTocItem]
        let indexEntries: [CHMIndexEntry]
    }

    struct NavigationRequest: Equatable {
        let id = UUID()
        let path: String
    }

    // MARK: 标签

    @Published var tabs: [ReaderTab] = []
    @Published var activeTabID: UUID?
    @Published var lastError: String?

    var activeTab: ReaderTab? { tabs.first { $0.id == activeTabID } }
    var document: Document? { tabs.first?.document }

    // MARK: 全书搜索(书级,同书标签共享)

    @Published var searchQuery = ""
    @Published var searchIndex: CHMSearchIndex?
    @Published var indexBuilding = false
    @Published var searchHits: [CHMSearchHit] = []

    // MARK: 页内查找

    struct FindAction: Equatable {
        let id = UUID()
        let query: String
        let direction: Int   // 0 首次, 1 下一个, -1 上一个
    }

    @Published var findVisible = false
    @Published var findQuery = ""
    @Published var findStatus = ""
    @Published var findAction: FindAction?

    // MARK: 书签(书级)

    @Published var bookmarks: [CHMBookmark] = []
    var bookmarkStore: CHMBookmarkStore?
    private var tocTitleMap: [String: String] = [:]

    // MARK: 显示设置与阅读状态

    @Published var settings = CHMDisplaySettings()
    @Published var settingsVisible = false
    @Published var recents: [String] = []
    let settingsStore: CHMSettingsStore
    let readingStateStore: CHMReadingStateStore

    var canGoBack: Bool { activeTab?.history.canGoBack ?? false }
    var canGoForward: Bool { activeTab?.history.canGoForward ?? false }
    var isCurrentPageBookmarked: Bool {
        guard let p = activeTab?.currentPath else { return false }
        return bookmarkStore?.bookmarks.contains { $0.path == p } ?? false
    }

    private var smokeStage = 0
    private var smoke: Bool { ProcessInfo.processInfo.environment["CHIMERA_SMOKE"] == "1" }

    /// 供 AppDelegate 打开事件路由(Finder 双击 .chm / Dock 拖放)
    static weak var shared: AppModel?

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Chimera", isDirectory: true)
        settingsStore = CHMSettingsStore(storageURL: dir.appendingPathComponent("Settings.json"))
        readingStateStore = CHMReadingStateStore(
            storageURL: dir.appendingPathComponent("ReadingState.json"))
        settings = settingsStore.settings
        recents = readingStateStore.recents
        Self.shared = self
        if let auto = ProcessInfo.processInfo.environment["CHIMERA_AUTO_OPEN"] {
            open(url: URL(fileURLWithPath: (auto as NSString).expandingTildeInPath))
        }
    }

    // MARK: 打开

    func openPanel() {
        let panel = NSOpenPanel()
        panel.title = "打开 CHM 文件"
        panel.message = "选择一本 CHM 电子书"
        if let chmType = UTType(filenameExtension: "chm") {
            panel.allowedContentTypes = [chmType]
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            open(url: url)
        }
    }

    func open(url: URL) {
        do {
            let container = try CHMContainer(path: url.path)
            let info = try container.systemInfo()
            guard let topic = info?.defaultTopic, !topic.isEmpty else {
                throw CHMError.invalidFormat("缺少默认页(#SYSTEM code 2)")
            }
            let homePath = topic.hasPrefix("/") ? topic : "/" + topic

            var toc: [CHMTocItem] = []
            var indexEntries: [CHMIndexEntry] = []
            let allEntries = try container.allEntries()
            if let hhc = allEntries.first(where: { $0.path.hasSuffix(".hhc") })?.path {
                let text = CHMTextDecoder(lcid: info?.lcid).decode(try container.read(hhc))
                toc = CHMSitemapParser.parseTOC(text)
            }
            if let hhk = allEntries.first(where: { $0.path.hasSuffix(".hhk") })?.path {
                let text = CHMTextDecoder(lcid: info?.lcid).decode(try container.read(hhk))
                indexEntries = CHMSitemapParser.parseIndex(text)
            }
            if smoke {
                print("OPEN toc=\(toc.count) index=\(indexEntries.count)")
            }

            let doc = Document(url: url, container: container, homePath: homePath,
                               toc: toc, indexEntries: indexEntries)

            bookmarkStore = CHMBookmarkStore(storageURL: CHMBookmarkStore.storageURL(for: url))
            bookmarks = bookmarkStore?.bookmarks ?? []
            tocTitleMap = Self.tocTitles(from: toc)

            // 状态记忆:恢复上次阅读位置(条目仍存在时),并登记最近打开
            let lastPath = readingStateStore.lastPath(forBookKey: url.path)
            let restore = lastPath.flatMap { container.entry(at: $0) != nil ? lastPath : nil }
            let tab = ReaderTab(document: doc, model: self, loadPath: restore)
            tabs = [tab]
            activeTabID = tab.id
            readingStateStore.recordRecent(url.path)
            recents = readingStateStore.recents
            lastError = nil
            buildIndexIfNeeded()
        } catch {
            tabs = []
            activeTabID = nil
            lastError = "\(error)"
            if smoke {
                print("SMOKE FAIL \(error)")
                exit(1)
            }
        }
    }

    // MARK: 标签管理

    /// 同书新标签(默认页);指定 path 时打开对应章节。
    @discardableResult
    func newTab(path: String? = nil) -> ReaderTab? {
        guard let doc = document else { return nil }
        let tab = ReaderTab(document: doc, model: self, loadPath: path)
        tabs.append(tab)
        activeTabID = tab.id
        return tab
    }

    /// 侧栏"在新标签页打开"。
    func openInNewTab(_ path: String) {
        guard newTab(path: path) != nil else { return }
    }

    func closeActiveTab() {
        closeTab(id: activeTabID)
    }

    func closeTab(id: UUID?) {
        guard let id else { return }
        tabs.removeAll { $0.id == id }
        if activeTabID == id {
            activeTabID = tabs.last?.id
        }
    }

    // MARK: 导航

    func navigate(to local: String) {
        activeTab?.requestNav(local)
    }

    func goBack() { activeTab?.goBack() }
    func goForward() { activeTab?.goForward() }

    // MARK: 搜索 / 查找 / 书签

    func runSearch() {
        guard let idx = searchIndex else { searchHits = []; return }
        searchHits = idx.search(searchQuery, limit: 200)
    }

    static func tocTitles(from items: [CHMTocItem]) -> [String: String] {
        var map: [String: String] = [:]
        func walk(_ items: [CHMTocItem]) {
            for it in items {
                if let l = it.local {
                    if map[l] == nil { map[l] = it.title }
                    if map["/" + l] == nil { map["/" + l] = it.title }
                }
                walk(it.children)
            }
        }
        walk(items)
        return map
    }

    func buildIndexIfNeeded() {
        guard let doc = document, searchIndex == nil, !indexBuilding else { return }
        let cacheURL = CHMSearchIndex.cacheURL(for: doc.url)

        if smoke {
            indexBuilding = true
            let idx = CHMSearchIndex.load(from: cacheURL)
                ?? (try? CHMSearchIndex.build(container: doc.container,
                                              tocTitles: Self.tocTitles(from: doc.toc)))
            indexBuilding = false
            searchIndex = idx
            if let idx { try? idx.save(to: cacheURL) }
            return
        }

        indexBuilding = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var idx = CHMSearchIndex.load(from: cacheURL)
            if idx == nil {
                idx = try? CHMSearchIndex.build(container: doc.container,
                                                tocTitles: Self.tocTitles(from: doc.toc))
                if let built = idx { try? built.save(to: cacheURL) }
            }
            DispatchQueue.main.async {
                self?.searchIndex = idx
                self?.indexBuilding = false
            }
        }
    }

    func startFind() {
        let q = findQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { findStatus = ""; return }
        findAction = FindAction(query: q, direction: 0)
    }

    func triggerFind(next: Bool) {
        let q = findQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { findStatus = ""; return }
        findAction = FindAction(query: q, direction: next ? 1 : -1)
    }

    func toggleBookmark() {
        guard let p = activeTab?.currentPath, let store = bookmarkStore else { return }
        if store.bookmarks.contains(where: { $0.path == p }) {
            store.remove(path: p)
        } else {
            let title = tocTitleMap[p] ?? tocTitleMap[String(p.dropFirst())] ?? p
            store.add(p, title: title)
        }
        bookmarks = store.bookmarks
    }

    func removeBookmark(id: UUID) {
        bookmarkStore?.remove(id: id)
        bookmarks = bookmarkStore?.bookmarks ?? []
    }

    // MARK: 显示设置 / 缩放 / 阅读状态保存

    func updateSettings(font: String? = nil, size: Double? = nil) {
        var s = settings
        if let font { s.fontFamily = font }
        if let size { s.fontSize = size }
        settings = s
        settingsStore.update(s)
        for tab in tabs { tab.applyFont(s) }
    }

    func zoom(delta: Double = 0, reset: Bool = false) {
        guard let tab = activeTab else { return }
        let target = reset ? 1.0 : min(3.0, max(0.5, tab.webView.magnification + delta))
        tab.webView.setMagnification(target, centeredAt: .zero)
    }

    fileprivate func tabDidCommitPath(_ path: String, bookURL: URL) {
        readingStateStore.setLastPath(path, forBookKey: bookURL.path)
    }

    // MARK: 冒烟状态机(统一驱动 NAV/SEARCH/FIND/HISTORY/TABS 链路)

    fileprivate func tabDidFinish(_ tab: ReaderTab, textLen: Int) {
        guard smoke else { return }
        smokeStage += 1
        let env = ProcessInfo.processInfo.environment

        func fail(_ msg: String) -> Never {
            print("SMOKE FAIL stage\(smokeStage) \(msg)")
            exit(1)
        }

        switch smokeStage {
        case 1:
            guard textLen > 0 else { fail("textLen=\(textLen)") }
            if let fq = env["CHIMERA_FIND"] {
                findQuery = fq
                findVisible = true
                startFind()
                return   // 结果由 findAction 订阅打印并退出
            }
            if let q = env["CHIMERA_SEARCH"], let idx = searchIndex {
                let hits = idx.search(q)
                print("SEARCH q=\(q) hits=\(hits.count) first=\(hits.first?.path ?? "-")")
                guard let first = hits.first else {
                    print("SMOKE OK search-nohits"); exit(0)
                }
                tab.pendingHighlight = q
                tab.requestNav(first.path)
                return
            }
            if let nav = env["CHIMERA_NAV"] {
                print("SMOKE NAV(env) -> \(nav)")
                tab.requestNav(nav)
                return
            }
            print("SMOKE OK url=\(tab.currentPath ?? "-") textLen=\(textLen)")
            exit(0)

        case 2:
            guard textLen > 0 else { fail("stage2 textLen=\(textLen)") }
            if env["CHIMERA_RESTORE"] == "1" {
                print("REOPEN \(tab.document.url.lastPathComponent)")
                open(url: tab.document.url)
                return
            }
            if env["CHIMERA_TABS"] == "1" {
                print("TAB1 second=\(tab.currentPath ?? "-")")
                newTab()
                return
            }
            if env["CHIMERA_HISTORY"] == "1" {
                tab.goBack()
                return
            }
            print("SMOKE OK url2=\(tab.currentPath ?? "-") textLen=\(textLen)")
            exit(0)

        case 3:
            guard textLen > 0 else { fail("stage3 textLen=\(textLen)") }
            if env["CHIMERA_RESTORE"] == "1" {
                let expected = env["CHIMERA_NAV"] ?? ""
                let exp = expected.hasPrefix("/") ? expected : "/" + expected
                let ok = tab.currentPath == exp
                print("RESTORE restored=\(tab.currentPath ?? "-") ok=\(ok)")
                exit(ok ? 0 : 1)
            }
            if env["CHIMERA_TABS"] == "1" {
                print("TAB2 home=\(tab.currentPath ?? "-")")
                guard let first = tabs.first, first !== tab else { fail("tabs 状态异常") }
                first.goBack()
                return
            }
            if env["CHIMERA_HISTORY"] == "1" {
                let homeOK = tab.currentPath == tab.document.homePath
                print("HISTORY back=\(tab.currentPath ?? "-") homeOK=\(homeOK)")
                exit(homeOK ? 0 : 1)
            }
            exit(0)

        case 4:
            // TABS 第 4 阶段:tab1 后退回默认页 → 两标签历史独立
            let homeOK = tab.currentPath == tab.document.homePath
            print("TABS tab1Back=\(tab.currentPath ?? "-") independent=\(homeOK) tabs=\(tabs.count)")
            exit(homeOK && tabs.count == 2 ? 0 : 1)

        default:
            exit(0)
        }
    }

    /// 从前 4KB 粗提 <meta charset=…>。
    static func charsetDeclared(in data: Data) -> String? {
        let head = String(decoding: data.prefix(4096), as: UTF8.self)
        guard let r = head.range(of: "charset=", options: .caseInsensitive) else { return nil }
        var s = head[r.upperBound...]
        if s.first == "\"" || s.first == "'" {
            let quote = s.removeFirst()
            guard let end = s.firstIndex(of: quote) else { return nil }
            s = s[..<end]
        } else if let end = s.firstIndex(where: { $0 == ";" || $0 == ">" || $0.isWhitespace }) {
            s = s[..<end]
        }
        let name = s.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}

// MARK: - 标签(每标签独立 webview/历史/导航)

final class ReaderTab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate {
    let id = UUID()
    let document: AppModel.Document
    let webView: WKWebView
    weak var model: AppModel?

    @Published var history = CHMHistory()
    @Published var currentPath: String?
    @Published var navigationRequest: AppModel.NavigationRequest?
    /// 搜索跳转后待高亮的检索词
    var pendingHighlight: String?

    private var cancellables = Set<AnyCancellable>()

    var title: String { model?.document?.url.lastPathComponent ?? "CHM" }

    init(document: AppModel.Document, model: AppModel, loadPath: String?) {
        self.document = document
        self.model = model

        let container = document.container
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(CHMSchemeHandler(provider: { container }), forURLScheme: "chm")
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

    private func load(path rawPath: String) {
        let path = rawPath.hasPrefix("/") ? rawPath : "/" + rawPath
        var comps = URLComponents()
        comps.scheme = "chm"
        comps.host = "doc"
        comps.path = path
        if let u = comps.url {
            webView.load(URLRequest(url: u))
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let url = webView.url, url.scheme?.lowercased() == "chm" {
            currentPath = url.path
            history.push(url.path)
            model?.tabDidCommitPath(url.path, bookURL: document.url)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let smoke = ProcessInfo.processInfo.environment["CHIMERA_SMOKE"] == "1"
        if let q = pendingHighlight {
            pendingHighlight = nil
            webView.evaluateJavaScript(Self.highlightJS(q)) { result, _ in
                if smoke { print("HIGHLIGHT count=\((result as? Int) ?? 0)") }
            }
        }
        if let m = model { applyFont(m.settings) }
        if smoke {
            webView.evaluateJavaScript("document.body ? document.body.innerText.length : -1") { r, _ in
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

    /// 用户字体注入(每次页面加载与设置变更时应用)。
    static func fontJS(_ s: CHMDisplaySettings) -> String {
        let fam = s.fontFamily.map { "'" + $0.replacingOccurrences(of: "'", with: "") + "', " } ?? ""
        return """
        (function(){var e=document.getElementById('chimera-font-style');
        if(!e){e=document.createElement('style');e.id='chimera-font-style';document.head.appendChild(e);}
        e.textContent='*{font-family:\(fam)-apple-system,system-ui,sans-serif !important;font-size:\(Int(s.fontSize))px !important;}';
        return 1;})()
        """
    }

    /// 命中词高亮:文本节点包裹 <mark> 并滚动到首个命中。
    static func highlightJS(_ query: String) -> String {
        let q = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return """
        (function(){
          var q='\(q)'; if(!q) return 0;
          var count=0;
          var walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);
          var nodes=[]; while(walker.nextNode()) nodes.push(walker.currentNode);
          nodes.forEach(function(n){
            var t=n.nodeValue; if(!t) return;
            var lt=t.toLowerCase(); var i=lt.indexOf(q.toLowerCase()); if(i<0) return;
            var frag=document.createDocumentFragment(); var pos=0;
            while(i>=0){
              frag.appendChild(document.createTextNode(t.slice(pos,i)));
              var m=document.createElement('mark');
              m.style.backgroundColor='#ffe066'; m.style.color='inherit';
              m.textContent=t.substr(i,q.length);
              frag.appendChild(m); count++;
              pos=i+q.length; i=lt.indexOf(q.toLowerCase(),pos);
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
        let q = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return """
        (function(){
          var q='\(q)'; if(!q) return '0/0';
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

// MARK: - 视图

struct ReaderView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if !model.tabs.isEmpty {
                TabBar(model: model)
            }
            NavigationSplitView {
                SidebarView(model: model)
                    .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 460)
            } detail: {
                ZStack(alignment: .top) {
                    if model.tabs.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "book")
                                .font(.system(size: 56))
                                .foregroundStyle(.secondary)
                            Text(model.lastError ?? "打开一本 CHM 开始阅读")
                                .font(.title3)
                                .foregroundStyle(model.lastError == nil ? Color.secondary : Color.red)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                            Button("打开…") { model.openPanel() }
                                .keyboardShortcut("o", modifiers: .command)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ZStack {
                            ForEach(model.tabs) { tab in
                                TabWebView(tab: tab)
                                    .opacity(model.activeTabID == tab.id ? 1 : 0)
                                    .allowsHitTesting(model.activeTabID == tab.id)
                            }
                        }
                        .toolbar {
                            ToolbarItemGroup(placement: .navigation) {
                                GoBackButton(model: model)
                                GoForwardButton(model: model)
                            }
                            ToolbarItem(placement: .primaryAction) {
                                BookmarkButton(model: model)
                            }
                        }
                    }
                    if model.findVisible {
                        FindBar(model: model)
                    }
                }
            }
        }
        .sheet(isPresented: $model.settingsVisible) { SettingsPanel(model: model) }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let p = providers.first(where: {
                $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            }) else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    if let url, url.pathExtension.lowercased() == "chm" {
                        model.open(url: url)
                    }
                }
            }
            return true
        }
    }
}

/// 显示设置面板:字体/字号,即时生效并持久化。
struct SettingsPanel: View {
    @ObservedObject var model: AppModel

    private let fonts: [(String, String?)] = [
        ("默认(系统)", nil),
        ("苹方 PingFang SC", "PingFang SC"),
        ("宋体 Songti SC", "Songti SC"),
        ("楷体 Kaiti SC", "Kaiti SC"),
        ("仿宋 STFangsong", "STFangsong"),
        ("黑体 STHeiti", "STHeiti"),
    ]

    var body: some View {
        VStack(spacing: 16) {
            Text("显示设置").font(.title3)
            Picker("字体", selection: Binding<String?>(
                get: { model.settings.fontFamily },
                set: { model.updateSettings(font: $0) }
            )) {
                ForEach(fonts, id: \.0) { name, value in
                    Text(name).tag(value)
                }
            }
            .pickerStyle(.radioGroup)
            HStack {
                Text("字号 \(Int(model.settings.fontSize)) px")
                    .monospacedDigit()
                Slider(value: Binding<Double>(
                    get: { model.settings.fontSize },
                    set: { model.updateSettings(size: $0) }
                ), in: 12...24, step: 1)
            }
            Button("完成") { model.settingsVisible = false }
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 340)
    }
}

// MARK: 标签栏

struct TabBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(model.tabs) { tab in
                TabBarItem(model: model, tab: tab)
            }
            Button { model.newTab() } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .padding(.horizontal, 4)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }
}

struct TabBarItem: View {
    @ObservedObject var model: AppModel
    @ObservedObject var tab: ReaderTab

    private var active: Bool { model.activeTabID == tab.id }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "book")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(tab.title)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 150)
            Button {
                model.closeTab(id: tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            active ? Color(nsColor: .controlBackgroundColor) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(active ? Color(nsColor: .controlColor) : Color.clear,
                              lineWidth: 0.8)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.activeTabID = tab.id }
    }
}

// MARK: 工具栏按钮(观察活动标签以驱动禁用态)

private struct GoBackButton: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ObservedTabButton(model: model) { tab in
            Button { tab.goBack() } label: { Image(systemName: "chevron.backward") }
                .disabled(!tab.history.canGoBack)
                .keyboardShortcut("[", modifiers: .command)
        }
    }
}

private struct GoForwardButton: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ObservedTabButton(model: model) { tab in
            Button { tab.goForward() } label: { Image(systemName: "chevron.forward") }
                .disabled(!tab.history.canGoForward)
                .keyboardShortcut("]", modifiers: .command)
        }
    }
}

private struct BookmarkButton: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ObservedTabButton(model: model) { tab in
            Button { model.toggleBookmark() } label: {
                Image(systemName: model.isCurrentPageBookmarked ? "bookmark.fill" : "bookmark")
            }
            .disabled(tab.currentPath == nil)
        }
    }
}

/// 包装:让工具栏子视图观察当前活动标签(历史/路径变化驱动 UI)。
private struct ObservedTabButton<Content: View>: View {
    @ObservedObject var model: AppModel
    @ViewBuilder var content: (ReaderTab) -> Content

    var body: some View {
        if let tab = model.activeTab {
            TabObserver(tab: tab, content: content)
        }
    }
}

private struct TabObserver<Content: View>: View {
    @ObservedObject var tab: ReaderTab
    @ViewBuilder var content: (ReaderTab) -> Content

    var body: some View { content(tab) }
}

// MARK: - 侧栏

struct SidebarView: View {
    @ObservedObject var model: AppModel
    // CLT 环境无 SwiftUIMacros 插件(@State 宏不可用),
    // 本地 UI 状态改由 ObservableObject 持有(@StateObject 已验证可用,见 DEV_ENV.md)
    @StateObject private var state = SidebarState()

    enum SidebarTab: Hashable { case toc, index, search, marks }

    final class SidebarState: ObservableObject {
        @Published var tab = SidebarTab.toc
        @Published var indexQuery = ""
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("侧栏", selection: $state.tab) {
                Text("目录").tag(SidebarTab.toc)
                Text("索引").tag(SidebarTab.index)
                Text("搜索").tag(SidebarTab.search)
                Text("书签").tag(SidebarTab.marks)
            }
            .pickerStyle(.segmented)
            .padding(8)

            switch state.tab {
            case .toc:
                if let toc = model.document?.toc {
                    let tree = toc.map(TOCTreeNode.init)
                    List(tree, children: \.children) { node in
                        TOCRow(item: node.item, onOpen: { model.navigate(to: $0) }) {
                            model.openInNewTab($0)
                        }
                    }
                    .listStyle(.sidebar)
                }
            case .marks:
                Group {
                    if model.bookmarks.isEmpty {
                        Text("暂无书签(工具栏 ⚑ 添加)")
                            .foregroundStyle(.secondary).font(.caption).padding()
                    } else {
                        List(model.bookmarks) { bm in
                            HStack {
                                Image(systemName: "bookmark.fill")
                                    .foregroundStyle(.yellow).font(.caption)
                                Text(bm.title).lineLimit(1)
                                Spacer()
                                Button { model.removeBookmark(id: bm.id) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.borderless).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { model.navigate(to: bm.path) }
                        }
                    }
                }
            case .search:
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("搜索全书…", text: $model.searchQuery)
                            .textFieldStyle(.plain)
                            .onSubmit { model.runSearch() }
                        if !model.searchQuery.isEmpty {
                            Button("✕") { model.searchQuery = ""; model.runSearch() }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                    }
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(nsColor: .separatorColor))
                    )
                    .padding([.horizontal, .top], 8)

                    if model.indexBuilding {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("建立索引…").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    } else if model.searchHits.isEmpty {
                        Text(model.searchQuery.isEmpty ? "输入关键词回车搜索全书" : "无命中")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                            .padding()
                    } else {
                        List(model.searchHits, id: \.path) { hit in
                            Button {
                                model.activeTab?.pendingHighlight = model.searchQuery
                                model.navigate(to: hit.path)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(hit.title).lineLimit(1)
                                    Text(hit.snippet)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            case .index:
                VStack(spacing: 4) {
                    TextField("过滤索引…", text: $state.indexQuery)
                        .textFieldStyle(.roundedBorder)
                        .padding([.horizontal, .top], 8)
                    List(filteredIndex, id: \.self) { entry in
                        Button {
                            if let t = entry.targets.first { model.navigate(to: t) }
                        } label: {
                            HStack {
                                Text(entry.keyword).lineLimit(1)
                                Spacer()
                                if entry.targets.count > 1 {
                                    Text("\(entry.targets.count)").foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if filteredIndex.isEmpty {
                        Text("无索引项").foregroundStyle(.secondary).padding()
                    }
                }
            }
        }
    }

    private var filteredIndex: [CHMIndexEntry] {
        let all = model.document?.indexEntries ?? []
        guard !state.indexQuery.isEmpty else { return all }
        return all.filter { $0.keyword.localizedCaseInsensitiveContains(state.indexQuery) }
    }
}

/// List(children:) 需要可选子节点;包装 CHMTocItem 并提供稳定 id。
struct TOCTreeNode: Identifiable {
    let item: CHMTocItem
    let children: [TOCTreeNode]?   // nil = 叶子

    init(_ item: CHMTocItem) {
        self.item = item
        self.children = item.children.isEmpty ? nil : item.children.map(TOCTreeNode.init)
    }

    var id: String { (item.local ?? "") + "|" + item.title }
}

struct TOCRow: View {
    let item: CHMTocItem
    let onOpen: (String) -> Void
    var onOpenInTab: ((String) -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: item.children.isEmpty ? "doc.text" : "book.closed")
                .foregroundStyle(.secondary)
                .font(.callout)
            Text(item.title)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let local = item.local { onOpen(local) }
        }
        .contextMenu {
            if let local = item.local, let onOpenInTab {
                Button("在新标签页打开") { onOpenInTab(local) }
            }
        }
    }
}

/// 页内查找覆盖条(Cmd+F 唤起)。
struct FindBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("页内查找", text: $model.findQuery)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit { model.triggerFind(next: true) }
            Button { model.triggerFind(next: false) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
            Button { model.triggerFind(next: true) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
            Text(model.findStatus).font(.caption).foregroundStyle(.secondary).frame(width: 44)
            Spacer()
            Button { model.findVisible = false; model.findStatus = "" } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(8)
    }
}

/// 标签内容:直接挂载该标签自持有的 WKWebView。
struct TabWebView: NSViewRepresentable {
    @ObservedObject var tab: ReaderTab

    func makeNSView(context: Context) -> WKWebView { tab.webView }
    func updateNSView(_ wv: WKWebView, context: Context) {}
}
