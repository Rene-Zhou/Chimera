import Testing
import Foundation
@testable import ChimeraCore

// MARK: - 历史栈

@Test func historyPushBackForward() {
    var h = CHMHistory()
    #expect(h.current == nil)

    h.push("/a.htm")
    h.push("/b.htm")
    h.push("/c.htm")
    #expect(h.current == "/c.htm")
    #expect(h.canGoBack)
    #expect(!h.canGoForward)

    #expect(h.goBack() == "/b.htm")
    #expect(h.current == "/b.htm")
    #expect(h.canGoBack)
    #expect(h.canGoForward)

    #expect(h.goForward() == "/c.htm")
    #expect(!h.canGoForward)

    #expect(h.goBack() == "/b.htm")
    #expect(h.goBack() == "/a.htm")
    #expect(!h.canGoBack)
    #expect(h.goBack() == nil, "栈底再退返回 nil")
}

@Test func historyDedupAndForwardReset() {
    var h = CHMHistory()
    h.push("/a.htm")
    h.push("/a.htm")   // 重复路径不产生历史项
    #expect(h.backStack.isEmpty)

    h.push("/b.htm")
    _ = h.goBack()      // 回到 a,forward=[b]
    h.push("/c.htm")    // 新分支 → forward 清空
    #expect(!h.canGoForward)
    #expect(h.current == "/c.htm")
    #expect(h.backStack == ["/a.htm"])
}

@Test func historyPeekHelpers() {
    var h = CHMHistory()
    #expect(h.backPeek == nil && h.forwardPeek == nil, "空栈 peek 均为 nil")

    h.push("/a.htm")
    h.push("/b.htm")
    h.push("/c.htm")
    #expect(h.backPeek == "/b.htm", "backPeek 是当前页的后退目标")
    #expect(h.forwardPeek == nil)

    _ = h.goBack()
    #expect(h.backPeek == "/a.htm")
    #expect(h.forwardPeek == "/c.htm", "forwardPeek 是前进目标")
}

// MARK: - 书签存储

@Test func bookmarkStorePersistsAcrossReload() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("chimera-bm-\(UUID().uuidString)", isDirectory: true)
    let url = dir.appendingPathComponent("bm.json")
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = CHMBookmarkStore(storageURL: url)
    store.add("/序章.htm", title: "序章")
    store.add("/序章.htm", title: "序章(重复)")   // 同路径去重
    store.add("/第一章.htm", title: "第一章")
    #expect(store.bookmarks.count == 2)
    #expect(store.bookmarks[0].title == "序章")

    store.remove(path: "/序章.htm")
    #expect(store.bookmarks.map(\.path) == ["/第一章.htm"])

    // “重启后仍在”:同一存储路径重新加载
    let reloaded = CHMBookmarkStore(storageURL: url)
    #expect(reloaded.bookmarks.count == 1)
    #expect(reloaded.bookmarks.first?.title == "第一章")
    #expect(reloaded.bookmarks.first?.addedAt.timeIntervalSinceNow ?? 0 > -60)
}
