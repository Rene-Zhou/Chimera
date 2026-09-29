import SwiftUI
import ChimeraCore

/// 设置窗口(Settings scene 根视图,Cmd+, / 「Chimera → 设置…」唤起)。
///
/// 与配置文件并存:读写与 `~/Library/Application Support/Chimera/Settings.json`
/// 同一个文件;打开时 reload 拾取外部手改,GUI 保存保留配置文件中的未知(高阶)键。
/// 注意:CLT 环境 @State 宏不可用,控件一律经 binding 直连 AppModel。
struct SettingsView: View {
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
        TabView {
            displayTab
                .tabItem { Label("显示", systemImage: "textformat.size") }
            readingTab
                .tabItem { Label("阅读", systemImage: "book") }
            searchTab
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
            generalTab
                .tabItem { Label("通用", systemImage: "gear") }
        }
        .frame(width: 440, height: 340)
        .onAppear {
            model.reloadSettings()
            model.refreshIndexCacheSize()
        }
    }

    /// 字段级绑定:修改即经 AppModel 持久化并即时生效。
    private func binding<V>(_ keyPath: WritableKeyPath<ChimeraSettings, V>) -> Binding<V> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { var s = model.settings; s[keyPath: keyPath] = $0; model.updateSettings(s) }
        )
    }

    // MARK: 显示

    private var displayTab: some View {
        Form {
            Picker("字体", selection: binding(\.fontFamily)) {
                ForEach(fonts, id: \.0) { name, value in
                    // 经 LocalizedStringKey 显式查表:"默认(系统)"有翻译,字体名无对应键则原样显示
                    Text(LocalizedStringKey(name)).tag(value)
                }
            }
            .pickerStyle(.radioGroup)
            HStack {
                Text("字号 \(Int(model.settings.fontSize)) px")
                    .monospacedDigit()
                Slider(value: binding(\.fontSize), in: 12...24, step: 1)
            }
            HStack {
                Text("行高 \(model.settings.lineHeight, specifier: "%.1f")")
                    .monospacedDigit()
                Slider(value: binding(\.lineHeight), in: 1.2...2.2, step: 0.1)
            }
            HStack {
                Toggle("限制内容宽度", isOn: Binding(
                    get: { model.settings.contentMaxWidth > 0 },
                    set: { on in
                        var s = model.settings
                        s.contentMaxWidth = on ? 900 : 0
                        model.updateSettings(s)
                    }
                ))
                if model.settings.contentMaxWidth > 0 {
                    Slider(value: binding(\.contentMaxWidth), in: 600...1400, step: 50)
                    Text("\(Int(model.settings.contentMaxWidth)) px")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Stepper(value: binding(\.defaultZoom), in: 0.5...3.0, step: 0.1) {
                HStack {
                    Text("默认缩放")
                    Spacer()
                    Text("\(Int((model.settings.defaultZoom * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: 阅读

    private var readingTab: some View {
        Form {
            Toggle("重新打开时恢复上次阅读位置", isOn: binding(\.restoreLastPosition))
            Toggle("记住页内滚动位置", isOn: binding(\.restoreScrollPosition))
            Toggle("启动时打开上次读的书", isOn: binding(\.restoreLastBook))
            Toggle("首次打开时目录全部展开", isOn: binding(\.tocDefaultExpanded))
            Toggle("打开外部链接前询问", isOn: binding(\.confirmExternalLinks))
            Section("外观") {
                Picker("外观", selection: binding(\.appearance)) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                .pickerStyle(.segmented)
                Toggle("网页内容强制暗色(实验)", isOn: binding(\.contentDarkMode))
            }
        }
        .formStyle(.grouped)
    }

    // MARK: 搜索

    private var searchTab: some View {
        Form {
            Stepper(value: binding(\.searchResultLimit), in: 50...1000, step: 50) {
                HStack {
                    Text("搜索结果上限")
                    Spacer()
                    Text("\(model.settings.searchResultLimit)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Section("索引缓存") {
                HStack {
                    Text("已占用 \(model.indexCacheSizeText)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("清理缓存") { model.clearIndexCache() }
                }
                Text("清理后下次打开书时会重建索引(首次搜索稍慢)。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: 通用

    private var generalTab: some View {
        Form {
            Picker("界面语言", selection: binding(\.language)) {
                Text("跟随系统").tag("system")
                Text("简体中文").tag("zh-Hans")
                Text("English").tag("en")
            }
            if model.settings.language != "system" {
                Text("语言切换将在重启应用后完全生效")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Stepper(value: binding(\.recentLimit), in: 1...50) {
                HStack {
                    Text("最近打开上限")
                    Spacer()
                    Text("\(model.settings.recentLimit)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("清空最近打开") { model.clearRecents() }
                    .disabled(model.recents.isEmpty)
                Spacer()
            }
            Section("配置文件") {
                Text(model.settingsFileURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack {
                    Button("打开配置文件…") { model.openSettingsFile() }
                    Button("在 Finder 中显示") { model.revealSettingsFile() }
                }
                Text("可手改该文件进行更高阶的自定义;GUI 保存时会保留其中的未知字段。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
