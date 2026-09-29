import Foundation

/// 应用设置(显示/阅读行为/搜索/通用)。
///
/// 与配置文件并存:持久化为单个 JSON 文件(默认
/// `~/Library/Application Support/Chimera/Settings.json`),用户可手改;
/// 解码时缺失键回退默认值、未知键忽略(由 store 合并写回保留)。
public struct ChimeraSettings: Codable, Equatable, Sendable {
    /// 字体族;nil = 系统默认栈。
    public var fontFamily: String?
    /// 正文字号(px)。
    public var fontSize: Double
    /// 正文行高(倍数)。
    public var lineHeight: Double
    /// 内容最大宽度(px);0 = 不限(随窗口)。
    public var contentMaxWidth: Double
    /// 默认缩放倍率(新标签/新页应用;Cmd+=/-/0 同步修改)。
    public var defaultZoom: Double
    /// 重新打开书时恢复上次阅读位置。
    public var restoreLastPosition: Bool
    /// 记住页内滚动位置(重开书时恢复到上次的滚动处)。
    public var restoreScrollPosition: Bool
    /// 启动时自动打开上次读的书。
    public var restoreLastBook: Bool
    /// 首次打开一本书时目录全部展开(之后按书记住展开状态)。
    public var tocDefaultExpanded: Bool
    /// 点击 http(s) 外链打开前弹确认框。
    public var confirmExternalLinks: Bool
    /// 界面外观:system / light / dark(作用于 app 界面)。
    public var appearance: String
    /// 网页内容强制暗色(实验性,filter 反色;图片二次反色还原)。
    public var contentDarkMode: Bool
    /// 界面语言:system / zh-Hans / en(改动需重启生效)。
    public var language: String
    /// 全书搜索结果上限。
    public var searchResultLimit: Int
    /// 「最近打开」列表上限。
    public var recentLimit: Int

    public init(fontFamily: String? = nil, fontSize: Double = 16,
                lineHeight: Double = 1.6, contentMaxWidth: Double = 0,
                defaultZoom: Double = 1.0,
                restoreLastPosition: Bool = true, restoreScrollPosition: Bool = true,
                restoreLastBook: Bool = false, tocDefaultExpanded: Bool = false,
                confirmExternalLinks: Bool = false,
                appearance: String = "system", contentDarkMode: Bool = false,
                language: String = "system",
                searchResultLimit: Int = 200, recentLimit: Int = 10) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.lineHeight = lineHeight
        self.contentMaxWidth = contentMaxWidth
        self.defaultZoom = defaultZoom
        self.restoreLastPosition = restoreLastPosition
        self.restoreScrollPosition = restoreScrollPosition
        self.restoreLastBook = restoreLastBook
        self.tocDefaultExpanded = tocDefaultExpanded
        self.confirmExternalLinks = confirmExternalLinks
        self.appearance = appearance
        self.contentDarkMode = contentDarkMode
        self.language = language
        self.searchResultLimit = searchResultLimit
        self.recentLimit = recentLimit
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case fontFamily, fontSize, lineHeight, contentMaxWidth, defaultZoom
        case restoreLastPosition, restoreScrollPosition, restoreLastBook
        case tocDefaultExpanded, confirmExternalLinks
        case appearance, contentDarkMode, language
        case searchResultLimit, recentLimit
    }

    /// 宽松解码:缺失键取默认值(向后兼容只含 fontFamily/fontSize 的旧文件)。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ChimeraSettings()
        fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily)
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? d.fontSize
        lineHeight = try c.decodeIfPresent(Double.self, forKey: .lineHeight) ?? d.lineHeight
        contentMaxWidth = try c.decodeIfPresent(Double.self, forKey: .contentMaxWidth)
            ?? d.contentMaxWidth
        defaultZoom = try c.decodeIfPresent(Double.self, forKey: .defaultZoom) ?? d.defaultZoom
        restoreLastPosition = try c.decodeIfPresent(Bool.self, forKey: .restoreLastPosition)
            ?? d.restoreLastPosition
        restoreScrollPosition = try c.decodeIfPresent(Bool.self, forKey: .restoreScrollPosition)
            ?? d.restoreScrollPosition
        restoreLastBook = try c.decodeIfPresent(Bool.self, forKey: .restoreLastBook)
            ?? d.restoreLastBook
        tocDefaultExpanded = try c.decodeIfPresent(Bool.self, forKey: .tocDefaultExpanded)
            ?? d.tocDefaultExpanded
        confirmExternalLinks = try c.decodeIfPresent(Bool.self, forKey: .confirmExternalLinks)
            ?? d.confirmExternalLinks
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? d.appearance
        contentDarkMode = try c.decodeIfPresent(Bool.self, forKey: .contentDarkMode)
            ?? d.contentDarkMode
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
        searchResultLimit = try c.decodeIfPresent(Int.self, forKey: .searchResultLimit)
            ?? d.searchResultLimit
        recentLimit = try c.decodeIfPresent(Int.self, forKey: .recentLimit) ?? d.recentLimit
    }
}

/// 设置存储(JSON 持久化,路径可注入)。
///
/// 合并写回:读入时保留原始 JSON 对象(含用户手加的高阶键),
/// 写回时仅覆盖已知键——GUI 保存不会丢配置文件里的未知自定义;
/// 文件损坏/不存在时回退默认值。
public final class CHMSettingsStore {
    public private(set) var settings: ChimeraSettings = ChimeraSettings()
    /// 磁盘文件的原始 JSON 对象(保留未知键)。
    private var raw: [String: Any] = [:]
    private let url: URL

    public init(storageURL: URL) {
        url = storageURL
        try? FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        load()
    }

    /// 重新从磁盘读取(供设置窗口打开时拾取外部编辑)。
    public func reload() { load() }

    private func load() {
        guard let data = try? Data(contentsOf: url) else {
            raw = [:]
            settings = ChimeraSettings()
            return
        }
        raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        settings = (try? JSONDecoder().decode(ChimeraSettings.self, from: data))
            ?? ChimeraSettings()
    }

    public func update(_ s: ChimeraSettings) {
        settings = s
        // 写回前先重读磁盘:保留 app 运行期间用户手加的未知(高阶)键
        if let data = try? Data(contentsOf: url),
           let diskRaw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            raw = diskRaw
        }
        guard let data = try? JSONEncoder().encode(s),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        // nil 字段(如 fontFamily)编码后缺席:从 raw 删除旧值,避免残留过期键
        let known = Set(ChimeraSettings.CodingKeys.allCases.map(\.stringValue))
        for k in known where obj[k] == nil { raw.removeValue(forKey: k) }
        for (k, v) in obj { raw[k] = v }
        if let out = try? JSONSerialization.data(
            withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: url, options: .atomic)
        }
    }
}

/// 单本书的阅读状态。
public struct CHMReadingState: Codable, Equatable {
    public var lastPath: String?
    /// 页内滚动位置:页面路径 → scrollY(px)。
    public var scrollPositions: [String: Double]
    public init(lastPath: String? = nil, scrollPositions: [String: Double] = [:]) {
        self.lastPath = lastPath
        self.scrollPositions = scrollPositions
    }
}

/// 阅读状态存储:每书最后页 + 最近打开列表(单 JSON 文件)。
public final class CHMReadingStateStore {
    struct Root: Codable {
        var books: [String: CHMReadingState] = [:]
        var recents: [String] = []
    }

    private(set) var root = Root()
    private let url: URL

    public init(storageURL: URL) {
        url = storageURL
        try? FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? Data(contentsOf: storageURL),
           let r = try? JSONDecoder().decode(Root.self, from: data) {
            root = r
        }
    }

    public func lastPath(forBookKey key: String) -> String? {
        root.books[key]?.lastPath
    }

    public func setLastPath(_ path: String?, forBookKey key: String) {
        var st = root.books[key] ?? CHMReadingState()
        st.lastPath = path
        root.books[key] = st
        save()
    }

    public func scrollY(forBookKey key: String, path: String) -> Double? {
        root.books[key]?.scrollPositions[path]
    }

    /// 记录某页的滚动位置(仅内存,滚动事件高频;由调用方防抖后调 flush() 落盘,
    /// 见 PERF_REVIEW P2-14)。超出上限时整体清空重计(避免长卷书无限增长)。
    public func setScrollY(_ y: Double, forBookKey key: String, path: String, limit: Int = 500) {
        var st = root.books[key] ?? CHMReadingState()
        if st.scrollPositions.count >= limit && st.scrollPositions[path] == nil {
            st.scrollPositions = [path: y]
        } else {
            st.scrollPositions[path] = y
        }
        root.books[key] = st
    }

    /// 把内存中的滚动位置落盘(setLastPath 等其他写入也会顺带保存)。
    public func flush() { save() }

    public var recents: [String] { root.recents }

    /// 去重置顶,上限 limit。
    public func recordRecent(_ path: String, limit: Int = 10) {
        root.recents.removeAll { $0 == path }
        root.recents.insert(path, at: 0)
        if root.recents.count > limit {
            root.recents = Array(root.recents.prefix(limit))
        }
        save()
    }

    public func clearRecents() {
        root.recents = []
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(root) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
