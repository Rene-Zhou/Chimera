import Testing
import Foundation
@testable import ChimeraCore

// MARK: - 显示设置

@Test func displaySettingsPersist() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("chimera-set-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    let store = CHMSettingsStore(storageURL: url)
    #expect(store.settings == CHMDisplaySettings())   // 默认值

    store.update(CHMDisplaySettings(fontFamily: "Songti SC", fontSize: 19))
    let reloaded = CHMSettingsStore(storageURL: url)
    #expect(reloaded.settings.fontFamily == "Songti SC")
    #expect(reloaded.settings.fontSize == 19)
}

// MARK: - 阅读状态(每书最后页 + 最近打开)

private func stateStore() throws -> (CHMReadingStateStore, URL) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("chimera-rs-\(UUID().uuidString).json")
    return (CHMReadingStateStore(storageURL: url), url)
}

@Test func readingStateLastPathRoundtrip() throws {
    let (store, url) = try stateStore()
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(store.lastPath(forBookKey: "/books/5r.chm") == nil)
    store.setLastPath("/第一章.htm", forBookKey: "/books/5r.chm")

    let reloaded = CHMReadingStateStore(storageURL: url)
    #expect(reloaded.lastPath(forBookKey: "/books/5r.chm") == "/第一章.htm")
    reloaded.setLastPath(nil, forBookKey: "/books/5r.chm")
    #expect(CHMReadingStateStore(storageURL: url).lastPath(forBookKey: "/books/5r.chm") == nil,
            "清空也应持久化")
}

@Test func recentsDedupTopAndLimit() throws {
    let (store, url) = try stateStore()
    defer { try? FileManager.default.removeItem(at: url) }

    store.recordRecent("/a.chm")
    store.recordRecent("/b.chm")
    store.recordRecent("/a.chm")          // 去重置顶
    #expect(store.recents == ["/a.chm", "/b.chm"])

    for i in 0..<15 { store.recordRecent("/n\(i).chm") }
    #expect(store.recents.count == 10, "上限 10")
    #expect(store.recents.first == "/n14.chm")

    let reloaded = CHMReadingStateStore(storageURL: url)
    #expect(reloaded.recents == store.recents)
}
