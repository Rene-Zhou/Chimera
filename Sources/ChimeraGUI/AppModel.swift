import Foundation
import AppKit
import CryptoKit
import UniformTypeIdentifiers
import ChimeraCore

// MARK: - 状态目录

/// 持久化根目录解析:默认 ~/Library/Application Support/Chimera;
/// CHIMERA_STATE_DIR 显式指定,或 CHIMERA_SMOKE=1 时使用进程级隔离临时目录,
/// 保证冒烟测试可重复且不污染真实用户数据。
enum ChimeraStateDir {
    /// 非 nil 表示处于隔离/覆盖模式。
    static let overrideRoot: URL? = {
        let env = ProcessInfo.processInfo.environment
        if let custom = env["CHIMERA_STATE_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        if env["CHIMERA_SMOKE"] == "1" {
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent(
                    "chimera-smoke-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        return nil
    }()

    /// 设置/阅读状态/书签/目录展开的统一根目录。
    static let root: URL = overrideRoot
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Chimera", isDirectory: true)

    /// 与 ChimeraCore 一致的书本摘要算法(SHA256 hex 前 24 位)。
    static func bookDigest(_ key: String) -> String {
        String(SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(24))
    }

    /// 书签存储位置:默认走 Core 规则;隔离模式下重定向到状态目录(键算法镜像 Core)。
    static func bookmarkStorageURL(for bookURL: URL) -> URL {
        guard overrideRoot != nil else { return CHMBookmarkStore.storageURL(for: bookURL) }
        let attrs = try? FileManager.default.attributesOfItem(atPath: bookURL.path)
        let size = attrs?[.size] as? Int ?? 0
        let dir = root.appendingPathComponent("Bookmarks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(bookDigest("\(bookURL.path)|\(size)")).json")
    }

    /// 目录展开状态存储位置(键算法同上)。
    static func tocExpansionStorageURL(for bookURL: URL) -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: bookURL.path)
        let size = attrs?[.size] as? Int ?? 0
        let dir = root.appendingPathComponent("TOCExpansion", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(bookDigest("\(bookURL.path)|\(size)")).json")
    }

    /// 搜索索引缓存位置:默认走 Core 规则;隔离模式下重定向(键算法镜像 Core:路径|大小|mtime)。
    static func indexCacheURL(for bookURL: URL) -> URL {
        guard overrideRoot != nil else { return CHMSearchIndex.cacheURL(for: bookURL) }
        let attrs = try? FileManager.default.attributesOfItem(atPath: bookURL.path)
        let size = attrs?[.size] as? Int ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(bookURL.path)|\(size)|\(String(format: "%.0f", mtime))"
        let dir = root.appendingPathComponent("IndexCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(bookDigest(key)).idx")
    }
}

/// 目录树展开状态存储:每本书持久化展开节点 id 集合(JSON,PRD F3)。
final class TOCExpansionStore {
    /// nil = 存储文件不存在(首次打开本书)。
    private(set) var expanded: Set<String>?
    private let fileURL: URL

    init(storageURL: URL) {
        fileURL = storageURL
        try? FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: storageURL),
           let list = try? JSONDecoder().decode([String].self, from: data) {
            expanded = Set(list)
        }
    }

    func save(_ expanded: Set<String>) {
        self.expanded = expanded
        if let data = try? JSONEncoder().encode(expanded.sorted()) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

// MARK: - 文档模型

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
    /// 未截断的总命中数(用于"仅显示前 N 条"提示)。
    @Published var searchTotal = 0

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
    var tocTitleMap: [String: String] = [:]

    // MARK: 目录树展开状态(书级,持久化)

    @Published var tocExpanded: Set<String> = []
    private var tocExpansionStore: TOCExpansionStore?

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
        let dir = ChimeraStateDir.root
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
        panel.title = String(localized: "打开 CHM 文件")
        panel.message = String(localized: "选择一本 CHM 电子书")
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
        // 换书必须重置书级状态,否则搜索索引/命中/目录展开会沿用上一本
        searchQuery = ""
        searchHits = []
        searchTotal = 0
        searchIndex = nil
        indexBuilding = false
        findVisible = false
        findQuery = ""
        findStatus = ""
        findAction = nil
        bookmarks = []
        bookmarkStore = nil
        tocExpanded = []
        tocExpansionStore = nil
        do {
            let container = try CHMContainer(path: url.path)
            let info = try container.systemInfo()
            guard let topic = info?.defaultTopic, !topic.isEmpty else {
                throw CHMError.invalidFormat(String(localized: "缺少默认页(#SYSTEM code 2)"))
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

            bookmarkStore = CHMBookmarkStore(
                storageURL: ChimeraStateDir.bookmarkStorageURL(for: url))
            bookmarks = bookmarkStore?.bookmarks ?? []
            tocTitleMap = Self.tocTitles(from: toc)

            // 目录展开状态:有存档恢复存档;首次打开默认全部收起
            let expStore = TOCExpansionStore(
                storageURL: ChimeraStateDir.tocExpansionStorageURL(for: url))
            tocExpansionStore = expStore
            if let stored = expStore.expanded {
                tocExpanded = stored
            }

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

    // MARK: 目录展开

    func toggleTOCExpanded(_ id: String) {
        if tocExpanded.contains(id) {
            tocExpanded.remove(id)
        } else {
            tocExpanded.insert(id)
        }
        tocExpansionStore?.save(tocExpanded)
    }

    /// 全部展开(仅含子节点的目录项参与展开集合)。
    func expandAllTOC() {
        guard let doc = document else { return }
        var ids: Set<String> = []
        func walk(_ items: [CHMTocItem]) {
            for it in items where !it.children.isEmpty {
                ids.insert(TOCTreeNode(it).id)
                walk(it.children)
            }
        }
        walk(doc.toc)
        tocExpanded = ids
        tocExpansionStore?.save(ids)
    }

    func collapseAllTOC() {
        tocExpanded = []
        tocExpansionStore?.save([])
    }

    // MARK: 搜索 / 查找 / 书签

    func runSearch() {
        guard let idx = searchIndex else { searchHits = []; searchTotal = 0; return }
        let results = idx.searchResults(searchQuery, limit: 200)
        searchHits = results.hits
        searchTotal = results.total
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
        let cacheURL = ChimeraStateDir.indexCacheURL(for: doc.url)

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
        let bookURL = doc.url
        let tocTitles = Self.tocTitles(from: doc.toc)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var idx = CHMSearchIndex.load(from: cacheURL)
            if idx == nil {
                idx = try? CHMSearchIndex.build(container: doc.container,
                                                tocTitles: tocTitles)
                if let built = idx { try? built.save(to: cacheURL) }
            }
            DispatchQueue.main.async {
                // 构建期间可能已换书:校验当前文档身份再赋值,避免陈旧索引
                guard let self, self.document?.url == bookURL else { return }
                self.searchIndex = idx
                self.indexBuilding = false
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

    func tabDidCommitPath(_ path: String, bookURL: URL) {
        readingStateStore.setLastPath(path, forBookKey: bookURL.path)
    }

    // MARK: 冒烟状态机(统一驱动 NAV/SEARCH/FIND/HISTORY/TABS 链路)

    func tabDidFinish(_ tab: ReaderTab, textLen: Int) {
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
                // 走真实 UI 路径:searchQuery → runSearch()(而非绕过模型直查索引)
                _ = idx
                searchQuery = q
                runSearch()
                print("SEARCH q=\(q) hits=\(searchHits.count) total=\(searchTotal) first=\(searchHits.first?.path ?? "-")")
                guard let first = searchHits.first else {
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
}
