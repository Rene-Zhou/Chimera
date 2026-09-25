import Foundation

/// 显示设置(字体/字号)。
public struct CHMDisplaySettings: Codable, Equatable, Sendable {
    /// 字体族;nil = 系统默认栈。
    public var fontFamily: String?
    /// 正文字号(px)。
    public var fontSize: Double

    public init(fontFamily: String? = nil, fontSize: Double = 16) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
    }
}

/// 显示设置存储(JSON 持久化,路径可注入)。
public final class CHMSettingsStore {
    public private(set) var settings: CHMDisplaySettings
    private let url: URL

    public init(storageURL: URL) {
        url = storageURL
        try? FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? Data(contentsOf: storageURL),
           let s = try? JSONDecoder().decode(CHMDisplaySettings.self, from: data) {
            settings = s
        } else {
            settings = CHMDisplaySettings()
        }
    }

    public func update(_ s: CHMDisplaySettings) {
        settings = s
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// 单本书的阅读状态。
public struct CHMReadingState: Codable, Equatable {
    public var lastPath: String?
    public init(lastPath: String? = nil) {
        self.lastPath = lastPath
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

    private func save() {
        if let data = try? JSONEncoder().encode(root) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
