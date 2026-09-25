import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers
import ChimeraCore

// MARK: - 主视图

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
                            if let error = model.lastError {
                                Text(error)
                                    .font(.title3)
                                    .foregroundStyle(Color.red)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 32)
                            } else {
                                Text("打开一本 CHM 开始阅读")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 32)
                            }
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
                    // 经 LocalizedStringKey 显式查表:"默认(系统)"有翻译,字体名无对应键则原样显示
                    Text(LocalizedStringKey(name)).tag(value)
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
