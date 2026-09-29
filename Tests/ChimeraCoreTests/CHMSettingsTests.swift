import Testing
import Foundation
@testable import ChimeraCore

// MARK: - 应用设置

@Test func displaySettingsPersist() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("chimera-set-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    let store = CHMSettingsStore(storageURL: url)
    #expect(store.settings == ChimeraSettings())   // 默认值

    store.update(ChimeraSettings(fontFamily: "Songti SC", fontSize: 19))
    let reloaded = CHMSettingsStore(storageURL: url)
    #expect(reloaded.settings.fontFamily == "Songti SC")
    #expect(reloaded.settings.fontSize == 19)
}

/// 旧格式(仅 fontFamily/fontSize)解码:新字段回退默认值。
@Test func settingsDecodeLegacyFile() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("chimera-set-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    try #"{"fontFamily":"Kaiti SC","fontSize":18}"#.write(to: url, atomically: true, encoding: .utf8)
    let store = CHMSettingsStore(storageURL: url)
    #expect(store.settings.fontFamily == "Kaiti SC")
    #expect(store.settings.fontSize == 18)
    #expect(store.settings.restoreLastPosition == true)
    #expect(store.settings.confirmExternalLinks == false)
    #expect(store.settings.searchResultLimit == 200)
    #expect(store.settings.recentLimit == 10)
}

/// 合并写回:GUI 保存不丢用户手加的未知(高阶)键;nil 字段不残留旧值。
@Test func settingsMergePreservesUnknownKeys() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("chimera-set-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    try #"{"fontFamily":"Songti SC","experimentalFoo":42,"nested":{"a":[1,2]}}"#
        .write(to: url, atomically: true, encoding: .utf8)
    let store = CHMSettingsStore(storageURL: url)
    #expect(store.settings.fontFamily == "Songti SC")

    store.update(ChimeraSettings(fontSize: 20))   // fontFamily 置 nil
    let data = try Data(contentsOf: url)
    let obj = try #require(
        (try JSONSerialization.jsonObject(with: data)) as? [String: Any])
    #expect(obj["experimentalFoo"] as? Int == 42)
    #expect((obj["nested"] as? [String: Any])?["a"] as? [Int] == [1, 2])
    #expect(obj["fontSize"] as? Double == 20)
    #expect(obj["fontFamily"] == nil, "nil 字段应从文件中移除")

    let reloaded = CHMSettingsStore(storageURL: url)
    #expect(reloaded.settings.fontFamily == nil)
    #expect(reloaded.settings.fontSize == 20)
}

/// 阅读/显示新字段完整往返。
@Test func settingsNewFieldsRoundtrip() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("chimera-set-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    let store = CHMSettingsStore(storageURL: url)
    store.update(ChimeraSettings(
        lineHeight: 1.9, contentMaxWidth: 900, defaultZoom: 1.25,
        restoreLastBook: true, tocDefaultExpanded: true,
        appearance: "dark", contentDarkMode: true, language: "en"))
    let reloaded = CHMSettingsStore(storageURL: url)
    #expect(reloaded.settings.lineHeight == 1.9)
    #expect(reloaded.settings.contentMaxWidth == 900)
    #expect(reloaded.settings.defaultZoom == 1.25)
    #expect(reloaded.settings.restoreLastBook == true)
    #expect(reloaded.settings.tocDefaultExpanded == true)
    #expect(reloaded.settings.appearance == "dark")
    #expect(reloaded.settings.contentDarkMode == true)
    #expect(reloaded.settings.language == "en")
}

/// 运行期间外部新增未知键,GUI 保存(写回前重读磁盘)同样保留。
@Test func settingsMergePreservesKeysAddedAfterLoad() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("chimera-set-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    let store = CHMSettingsStore(storageURL: url)   // 文件尚不存在
    try #"{"experimentalFoo":42}"#.write(to: url, atomically: true, encoding: .utf8)

    store.update(ChimeraSettings(confirmExternalLinks: true))
    let data = try Data(contentsOf: url)
    let obj = try #require(
        (try JSONSerialization.jsonObject(with: data)) as? [String: Any])
    #expect(obj["experimentalFoo"] as? Int == 42, "运行期间手加的键也应保留")
    #expect(obj["confirmExternalLinks"] as? Bool == true)
}

/// reload:外部手改文件后重新读取生效。
@Test func settingsReloadPicksUpExternalEdits() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("chimera-set-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    let store = CHMSettingsStore(storageURL: url)
    store.update(ChimeraSettings(fontSize: 16))

    try #"{"fontSize":22,"searchResultLimit":500}"#
        .write(to: url, atomically: true, encoding: .utf8)
    store.reload()
    #expect(store.settings.fontSize == 22)
    #expect(store.settings.searchResultLimit == 500)
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

@Test func recentsClearAndCustomLimit() throws {
    let (store, url) = try stateStore()
    defer { try? FileManager.default.removeItem(at: url) }

    for i in 0..<5 { store.recordRecent("/n\(i).chm", limit: 3) }
    #expect(store.recents.count == 3, "自定义上限 3")
    #expect(store.recents.first == "/n4.chm")

    store.clearRecents()
    #expect(store.recents.isEmpty)
    #expect(CHMReadingStateStore(storageURL: url).recents.isEmpty, "清空应持久化")
}

@Test func scrollPositionsRoundtripAndFlush() throws {
    let (store, url) = try stateStore()
    defer { try? FileManager.default.removeItem(at: url) }

    store.setScrollY(320, forBookKey: "/b.chm", path: "/p1.htm")
    store.setScrollY(640, forBookKey: "/b.chm", path: "/p2.htm")
    store.setScrollY(42, forBookKey: "/b.chm", path: "/p1.htm")   // 覆盖
    #expect(store.scrollY(forBookKey: "/b.chm", path: "/p1.htm") == 42)

    // setScrollY 仅写内存;flush 后才持久化
    store.flush()
    let reloaded = CHMReadingStateStore(storageURL: url)
    #expect(reloaded.scrollY(forBookKey: "/b.chm", path: "/p1.htm") == 42)
    #expect(reloaded.scrollY(forBookKey: "/b.chm", path: "/p2.htm") == 640)
    #expect(reloaded.scrollY(forBookKey: "/b.chm", path: "/none.htm") == nil)

    // 其他写入(如 lastPath)也会顺带保存滚动位置
    let store2 = CHMReadingStateStore(storageURL: url)
    store2.setScrollY(7, forBookKey: "/b.chm", path: "/p3.htm")
    store2.setLastPath("/p3.htm", forBookKey: "/b.chm")
    #expect(CHMReadingStateStore(storageURL: url).scrollY(forBookKey: "/b.chm", path: "/p3.htm") == 7)
}
