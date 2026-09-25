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
        let html: String   // m2-1:默认页 HTML(m2-2 起改走 chm:// scheme 整站渲染)
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
            let data = try container.read(topic)
            let declared = Self.charsetDeclared(in: data)
            let html = CHMTextDecoder(lcid: info?.lcid, declaredCharset: declared).decode(data)
            document = Document(url: url, html: html)
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
        Group {
            if let doc = model.document {
                WebView(document: doc, model: model)
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

struct WebView: NSViewRepresentable {
    let document: AppModel.Document
    let model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let wv = WKWebView()
        context.coordinator.webView = wv
        wv.navigationDelegate = context.coordinator
        load(document, into: wv, coordinator: context.coordinator)
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        if context.coordinator.loadedDocumentID != document.id {
            load(document, into: wv, coordinator: context.coordinator)
        }
    }

    private func load(_ doc: AppModel.Document, into wv: WKWebView, coordinator: Coordinator) {
        coordinator.loadedDocumentID = doc.id
        wv.loadHTMLString(doc.html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var loadedDocumentID: UUID?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 冒烟验收:默认页渲染完成即报 OK 并退出(GUI 手测另行)
            if ProcessInfo.processInfo.environment["CHIMERA_SMOKE"] == "1" {
                let body = (webView.url?.absoluteString ?? "about:blank")
                print("SMOKE OK rendered=\(body) title=\(webView.title ?? "")")
                exit(0)
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
