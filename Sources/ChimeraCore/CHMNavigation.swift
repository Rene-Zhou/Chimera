import Foundation
import CryptoKit

/// 页面历史(前进/后退栈),UI 无关。
public struct CHMHistory: Equatable {
    public private(set) var current: String?
    public private(set) var backStack: [String] = []
    public private(set) var forwardStack: [String] = []

    public init() {}

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    /// 后退目标(栈顶的下一个);空栈返回 nil。
    public var backPeek: String? { backStack.last }
    /// 前进目标;空栈返回 nil。
    public var forwardPeek: String? { forwardStack.first }

    /// 新页入栈:与当前相同则忽略;新分支清空 forward。
    public mutating func push(_ path: String) {
        guard path != current else { return }
        if let c = current { backStack.append(c) }
        forwardStack.removeAll()
        current = path
    }

    /// 后退;栈底返回 nil。
    @discardableResult
    public mutating func goBack() -> String? {
        guard let prev = backStack.popLast() else { return nil }
        if let c = current { forwardStack.insert(c, at: 0) }
        current = prev
        return prev
    }

    /// 前进;栈顶返回 nil。
    @discardableResult
    public mutating func goForward() -> String? {
        guard let next = forwardStack.first else { return nil }
        forwardStack.removeFirst()
        if let c = current { backStack.append(c) }
        current = next
        return next
    }
}

/// 书签条目。
public struct CHMBookmark: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    /// 内部路径(以 "/" 开头)。
    public let path: String
    public let title: String
    public let addedAt: Date

    public init(path: String, title: String, addedAt: Date = Date()) {
        self.path = path
        self.title = title
        self.addedAt = addedAt
    }
}

/// 书签存储:JSON 持久化,存储路径可注入以便测试。
public final class CHMBookmarkStore {
    public private(set) var bookmarks: [CHMBookmark] = []
    private let fileURL: URL

    public init(storageURL: URL) {
        fileURL = storageURL
        try? FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? Data(contentsOf: storageURL),
           let list = try? JSONDecoder().decode([CHMBookmark].self, from: data) {
            bookmarks = list
        }
    }

    /// 书的持久化位置:Application Support/Chimera/Bookmarks/<path|size 摘要>.json
    public static func storageURL(for bookURL: URL) -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: bookURL.path)
        let size = attrs?[.size] as? Int ?? 0
        let key = "\(bookURL.path)|\(size)"
        let digest = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(24)
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Chimera/Bookmarks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(digest).json")
    }

    /// 添加(同路径去重)。
    public func add(_ path: String, title: String) {
        guard !bookmarks.contains(where: { $0.path == path }) else { return }
        bookmarks.append(CHMBookmark(path: path, title: title))
        save()
    }

    public func remove(id: UUID) {
        bookmarks.removeAll { $0.id == id }
        save()
    }

    public func remove(path: String) {
        bookmarks.removeAll { $0.path == path }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
