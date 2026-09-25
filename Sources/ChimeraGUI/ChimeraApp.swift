import SwiftUI
import AppKit
import ChimeraCore

@main
struct ChimeraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        // 单窗口场景:Window 只允许一个实例。运行中再次 open -a / Finder 双击
        // 不会再开新窗口,而是由 AppDelegate 把文件路由进既有窗口(AppModel.shared)。
        Window("Chimera", id: "main") {
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

// MARK: - 打开事件路由

/// Finder 双击/拖到 Dock 图标时经打开事件进入。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        // 处理全部传入 URL(一次可能拖入多本);同一进程内依次在现有窗口打开
        for u in urls where u.pathExtension.lowercased() == "chm" {
            AppModel.shared?.open(url: u)
        }
    }

    /// 单窗口阅读器:关窗即退出(避免窗口关闭后没有重建入口的半死状态)。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
