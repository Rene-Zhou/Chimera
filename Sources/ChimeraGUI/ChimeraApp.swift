import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers
import ChimeraCore

@main
struct ChimeraApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Chimera") {
            ReaderView(model: model)
                .frame(minWidth: 760, minHeight: 520)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开…") { model.openPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
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
        let homePath: String   // 如 "/玩家手册2024.htm"
        let toc: [CHMTocItem]
        let indexEntries: [CHMIndexEntry]
    }

    /// 侧栏/页内触发的导航请求。
    struct NavigationRequest: Equatable {
        let id = UUID()
        let path: String
    }

    @Published var navigationRequest: NavigationRequest?

    func navigate(to local: String) {
        guard !local.isEmpty else { return }
        navigationRequest = NavigationRequest(path: local)
    }

    @Published var document: Document?
    @Published var lastError: String?

    init() {
        if let auto = ProcessInfo.processInfo.environment["CHIMERA_AUTO_OPEN"] {
            open(url: URL(fileURLWithPath: (auto as NSString).expandingTildeInPath))
        }
    }

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
            if ProcessInfo.processInfo.environment["CHIMERA_SMOKE"] == "1" {
                print("OPEN toc=\(toc.count) index=\(indexEntries.count)")
            }

            document = Document(url: url, container: container, homePath: homePath,
                                toc: toc, indexEntries: indexEntries)
            lastError = nil
        } catch {
            document = nil
            lastError = "\(error)"
            if ProcessInfo.processInfo.environment["CHIMERA_SMOKE"] == "1" {
                print("SMOKE FAIL \(error)")
                exit(1)
            }
        }
    }

    /// 从前 4KB 粗提 <meta charset=…>(ASCII 层面扫描,解码前调用)。
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

// MARK: - 视图

struct ReaderView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 460)
        } detail: {
            if let doc = model.document {
                WebView(document: doc, model: model).id(doc.id)
            } else {
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
            }
        }
    }
}

// MARK: - 侧栏

struct SidebarView: View {
    @ObservedObject var model: AppModel
    // CLT 环境无 SwiftUIMacros 插件(@State 宏不可用),
    // 本地 UI 状态改由 ObservableObject 持有(@StateObject 已验证可用,见 DEV_ENV.md)
    @StateObject private var state = SidebarState()

    enum SidebarTab: Hashable { case toc, index }

    final class SidebarState: ObservableObject {
        @Published var tab = SidebarTab.toc
        @Published var indexQuery = ""
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("侧栏", selection: $state.tab) {
                Text("目录").tag(SidebarTab.toc)
                Text("索引").tag(SidebarTab.index)
            }
            .pickerStyle(.segmented)
            .padding(8)

            switch state.tab {
            case .toc:
                if let toc = model.document?.toc {
                    let tree = toc.map(TOCTreeNode.init)
                    List(tree, children: \.children) { node in
                        TOCRow(item: node.item) { model.navigate(to: $0) }
                    }
                    .listStyle(.sidebar)
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
    }
}

struct WebView: NSViewRepresentable {
    let document: AppModel.Document
    let model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(
            CHMSchemeHandler(provider: { [weak model] in model?.document?.container }),
            forURLScheme: "chm"
        )
        let wv = WKWebView(frame: .zero, configuration: config)
        context.coordinator.webView = wv
        wv.navigationDelegate = context.coordinator
        load(document, into: wv, coordinator: context.coordinator)
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        if let req = model.navigationRequest,
           context.coordinator.handledRequestID != req.id {
            context.coordinator.handledRequestID = req.id
            let path = req.path.hasPrefix("/") ? req.path : "/" + req.path
            var comps = URLComponents()
            comps.scheme = "chm"
            comps.host = "doc"
            comps.path = path
            if let u = comps.url {
                wv.load(URLRequest(url: u))
            }
        }
        if context.coordinator.loadedDocumentID != document.id {
            load(document, into: wv, coordinator: context.coordinator)
        }
    }

    private func load(_ doc: AppModel.Document, into wv: WKWebView, coordinator: Coordinator) {
        coordinator.loadedDocumentID = doc.id
        var comps = URLComponents()
        comps.scheme = "chm"
        comps.host = "doc"
        comps.path = doc.homePath
        if let url = comps.url {
            wv.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var loadedDocumentID: UUID?
        var handledRequestID: UUID?
        private var smokeStage = 0

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 冒烟验收(两阶段):①默认页渲染且正文非空 ②跟随页内首个链接再渲染
            guard ProcessInfo.processInfo.environment["CHIMERA_SMOKE"] == "1" else { return }
            smokeStage += 1
            webView.evaluateJavaScript(
                "document.body ? document.body.innerText.length : -1"
            ) { result, _ in
                let len = (result as? Int) ?? -1
                guard len > 0 else {
                    print("SMOKE FAIL stage\(self.smokeStage) textLen=\(len)")
                    exit(1)
                }
                if self.smokeStage == 1 {
                    webView.evaluateJavaScript(
                        "(function(){var a=document.querySelector('a[href]'); return a ? a.href : ''})()"
                    ) { href, _ in
                        if let h = href as? String, let u = URL(string: h),
                           u.scheme?.lowercased() == "chm" {
                            print("SMOKE NAV -> \(h)")
                            webView.load(URLRequest(url: u))
                        } else if let nav = ProcessInfo.processInfo.environment["CHIMERA_NAV"] {
                            var comps = URLComponents()
                            comps.scheme = "chm"
                            comps.host = "doc"
                            comps.path = nav.hasPrefix("/") ? nav : "/" + nav
                            if let u = comps.url {
                                print("SMOKE NAV(env) -> \(nav)")
                                webView.load(URLRequest(url: u))
                            } else {
                                print("SMOKE OK url=\(webView.url?.absoluteString ?? "-") textLen=\(len) nolink")
                                exit(0)
                            }
                        } else {
                            print("SMOKE OK url=\(webView.url?.absoluteString ?? "-") textLen=\(len) nolink")
                            exit(0)
                        }
                    }
                } else {
                    print("SMOKE OK url2=\(webView.url?.absoluteString ?? "-") textLen=\(len)")
                    exit(0)
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if ProcessInfo.processInfo.environment["CHIMERA_SMOKE"] == "1" {
                print("SMOKE FAIL load: \(error)")
                exit(1)
            }
        }
    }
}
