import SwiftUI
import AppKit
import ChimeraCore

// MARK: - 侧栏

struct SidebarView: View {
    @ObservedObject var model: AppModel
    // CLT 环境无 SwiftUIMacros 插件(@State 宏不可用),
    // 本地 UI 状态改由 ObservableObject 持有(@StateObject 已验证可用,见 DEV_ENV.md)
    @StateObject private var state = SidebarState()

    enum SidebarTab: Hashable { case toc, index, search, marks }

    final class SidebarState: ObservableObject {
        @Published var tab = SidebarTab.toc
        @Published var indexQuery = ""
        /// 全书搜索输入的本地副本:逐键只重绘搜索框本身,不再触发侧栏重算;
        /// 回车(onSubmit)才写回 model.searchQuery 并搜索。
        /// (冒烟 SEARCH 直接设 model.searchQuery + runSearch(),不经此字段,不受影响)
        @Published var searchInput = ""

        // MARK: TOC 扁平化 memoize:上次目录版本 + 展开集合未变则直接复用产物,
        // 免得每次 body 重算都重摊平整棵树(展开态上万节点);Set<String>
        // 与 Int 的相等比较远比 O(n) 摊平便宜。
        private var flatEdition = -1
        private var flatExpanded: Set<String> = []
        private var flatRowsCache: [TOCFlatRow] = []

        func flatRows(toc: [CHMTocItem], edition: Int, expanded: Set<String>) -> [TOCFlatRow] {
            if flatEdition == edition, flatExpanded == expanded { return flatRowsCache }
            flatEdition = edition
            flatExpanded = expanded
            flatRowsCache = TOCFlattener.flatten(toc, expanded: expanded)
            return flatRowsCache
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $state.tab) {
                Text("目录").tag(SidebarTab.toc)
                Text("索引").tag(SidebarTab.index)
                Text("搜索").tag(SidebarTab.search)
                Text("书签").tag(SidebarTab.marks)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            switch state.tab {
            case .toc:
                if model.document != nil {
                    // 自绘树:List(children:) 的整行点击会被展开手势吃掉,
                    // 既有 local 又有 children 的节点无法导航。改为递归行视图:
                    // 点标题=导航,点箭头=展开/收起,展开状态按书持久化(PRD F3)。
                    // 目录异步解析(bookTOC 后台回填)期间显示占位,完成后自动出现。
                    VStack(spacing: 0) {
                        HStack {
                            Spacer()
                            Button("全部收起") { model.collapseAllTOC() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("全部展开") { model.expandAllTOC() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 2)
                        if model.bookTOC.isEmpty {
                            Text("正在载入目录…")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 12)
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 2) {
                                    // 扁平化 + 懒加载:只渲染可见行,"全部展开"也不会瞬间生成数千视图;
                                    // 摊平结果按(目录版本,展开集合)memoize(见 SidebarState.flatRows)
                                    ForEach(state.flatRows(toc: model.bookTOC,
                                                           edition: model.bookTOCEdition,
                                                           expanded: model.tocExpanded)) { row in
                                        TOCRowView(
                                            row: row,
                                            expanded: model.tocExpanded.contains(row.id),
                                            onToggle: { model.toggleTOCExpanded(row.id) },
                                            onOpen: { local in
                                                if NSEvent.modifierFlags.contains(.command) {
                                                    model.openInNewTab(local)
                                                } else {
                                                    model.navigate(to: local)
                                                }
                                            },
                                            onOpenInNewTab: { model.openInNewTab($0) }
                                        )
                                    }
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 6)
                            }
                        }
                    }
                }
            case .marks:
                Group {
                    if model.bookmarks.isEmpty {
                        Text("暂无书签(工具栏 ⚑ 添加)")
                            .foregroundStyle(.secondary).font(.caption).padding()
                    } else {
                        List(model.bookmarks) { bm in
                            HStack {
                                Button {
                                    if NSEvent.modifierFlags.contains(.command) {
                                        model.openInNewTab(bm.path)
                                    } else {
                                        model.navigate(to: bm.path)
                                    }
                                } label: {
                                    HStack {
                                        Image(systemName: "bookmark.fill")
                                            .foregroundStyle(.yellow).font(.caption)
                                        Text(bm.title).lineLimit(1)
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).foregroundStyle(.primary)
                                Button { model.removeBookmark(id: bm.id) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.borderless).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            case .search:
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("搜索全书…", text: $state.searchInput)
                            .textFieldStyle(.plain)
                            .onSubmit {
                                model.searchQuery = state.searchInput
                                model.runSearch()
                            }
                        if !state.searchInput.isEmpty {
                            Button("✕") {
                                state.searchInput = ""
                                model.searchQuery = ""
                                model.runSearch()
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                    }
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(nsColor: .separatorColor))
                    )
                    .padding([.horizontal, .top], 8)

                    if model.indexBuilding {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("建立索引…").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    } else if model.searchHits.isEmpty {
                        Group {
                            if model.searchQuery.isEmpty {
                                Text("输入关键词回车搜索全书")
                            } else {
                                Text("无命中")
                            }
                        }
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .padding()
                    } else {
                        if model.searchTotal > model.searchHits.count {
                            Text("共 \(model.searchTotal) 条命中,仅显示前 \(model.searchHits.count) 条")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                        }
                        List(model.searchHits, id: \.path) { hit in
                            Button {
                                if NSEvent.modifierFlags.contains(.command) {
                                    model.openInNewTab(hit.path)
                                } else {
                                    model.activeTab?.pendingHighlight = model.searchQuery
                                    model.navigate(to: hit.path)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(hit.title).lineLimit(1)
                                    Text(hit.snippet)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            case .index:
                VStack(spacing: 4) {
                    TextField("过滤索引…", text: $state.indexQuery)
                        .textFieldStyle(.roundedBorder)
                        .padding([.horizontal, .top], 8)
                    List(filteredIndex, id: \.self) { entry in
                        Button {
                            if let t = entry.targets.first {
                                if NSEvent.modifierFlags.contains(.command) {
                                    model.openInNewTab(t)
                                } else {
                                    model.navigate(to: t)
                                }
                            }
                        } label: {
                            HStack {
                                Text(entry.keyword).lineLimit(1)
                                Spacer()
                                if entry.targets.count > 1 {
                                    Text("\(entry.targets.count)").foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if filteredIndex.isEmpty {
                        Text("无索引项").foregroundStyle(.secondary).padding()
                    }
                }
            }

            // 内容不足一屏时贴顶显示;否则会被侧栏列垂直居中,上方留出大片空白
            Spacer(minLength: 0)
        }
        // 换书重置/外部清空 searchQuery 时同步本地输入框,避免残留上一书的查询词
        .onChange(of: model.searchQuery) { q in
            if q.isEmpty { state.searchInput = "" }
        }
    }

    private var filteredIndex: [CHMIndexEntry] {
        let all = model.bookIndexEntries
        guard !state.indexQuery.isEmpty else { return all }
        return all.filter { $0.keyword.localizedCaseInsensitiveContains(state.indexQuery) }
    }
}

// MARK: - 目录树

/// 扁平化后的可见目录行:只含已展开分支的可见节点。
/// id 用索引路径("1.3.0")而非 标题+路径——基准书有大量同名同路径的
/// 分隔符节点("————"→分隔符.htm),后者会产生重复 id 破坏 ForEach diff。
struct TOCFlatRow: Identifiable {
    let id: String
    let item: CHMTocItem
    let depth: Int
    let hasChildren: Bool
}

enum TOCFlattener {
    /// 沿展开集合把树摊平成可见行;同时产出全部含子节点节点的 id(供"全部展开")。
    static func flatten(_ items: [CHMTocItem], expanded: Set<String>) -> [TOCFlatRow] {
        var rows: [TOCFlatRow] = []
        func walk(_ items: [CHMTocItem], _ depth: Int, _ prefix: String) {
            for (i, it) in items.enumerated() {
                let id = prefix.isEmpty ? "\(i)" : "\(prefix).\(i)"
                let has = !it.children.isEmpty
                rows.append(TOCFlatRow(id: id, item: it, depth: depth, hasChildren: has))
                if has, expanded.contains(id) { walk(it.children, depth + 1, id) }
            }
        }
        walk(items, 0, "")
        return rows
    }

    static func allParentIDs(_ items: [CHMTocItem]) -> Set<String> {
        var ids: Set<String> = []
        func walk(_ items: [CHMTocItem], _ prefix: String) {
            for (i, it) in items.enumerated() {
                let id = prefix.isEmpty ? "\(i)" : "\(prefix).\(i)"
                if !it.children.isEmpty {
                    ids.insert(id)
                    walk(it.children, id)
                }
            }
        }
        walk(items, "")
        return ids
    }
}

/// 单行目录:箭头=展开/收起,标题=导航(⌘+点击=新标签)。
/// 纯值类型 + 闭包,不观察 AppModel——避免模型任何变动都重渲染数千行。
struct TOCRowView: View {
    let row: TOCFlatRow
    let expanded: Bool
    let onToggle: () -> Void
    let onOpen: (String) -> Void
    let onOpenInNewTab: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            if row.hasChildren {
                Button(action: onToggle) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 14)
            }
            // 行本体用 Button 而非 onTapGesture:窗口未激活时
            // onTapGesture 的首次点击会被窗口激活吞掉,Button 可点击穿透
            Button {
                if let local = row.item.local {
                    onOpen(local)
                } else if row.hasChildren {
                    // 纯文件夹节点:点标题只切换展开
                    onToggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Text(row.item.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
        }
        .padding(.leading, CGFloat(row.depth) * 14)
        .padding(.vertical, 2)
        .contextMenu {
            if let local = row.item.local {
                Button("在新标签页打开") { onOpenInNewTab(local) }
            }
        }
    }
}
