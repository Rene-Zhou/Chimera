import SwiftUI
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
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("侧栏", selection: $state.tab) {
                Text("目录").tag(SidebarTab.toc)
                Text("索引").tag(SidebarTab.index)
                Text("搜索").tag(SidebarTab.search)
                Text("书签").tag(SidebarTab.marks)
            }
            .pickerStyle(.segmented)
            .padding(8)

            switch state.tab {
            case .toc:
                if let toc = model.document?.toc {
                    // 自绘树:List(children:) 的整行点击会被展开手势吃掉,
                    // 既有 local 又有 children 的节点无法导航。改为递归行视图:
                    // 点标题=导航,点箭头=展开/收起,展开状态按书持久化(PRD F3)。
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(toc.map(TOCTreeNode.init)) { node in
                                TOCNodeView(node: node, model: model, depth: 0)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
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
                                Image(systemName: "bookmark.fill")
                                    .foregroundStyle(.yellow).font(.caption)
                                Text(bm.title).lineLimit(1)
                                Spacer()
                                Button { model.removeBookmark(id: bm.id) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.borderless).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { model.navigate(to: bm.path) }
                        }
                    }
                }
            case .search:
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("搜索全书…", text: $model.searchQuery)
                            .textFieldStyle(.plain)
                            .onSubmit { model.runSearch() }
                        if !model.searchQuery.isEmpty {
                            Button("✕") { model.searchQuery = ""; model.runSearch() }
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
                        Text(model.searchQuery.isEmpty ? "输入关键词回车搜索全书" : "无命中")
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
                                model.activeTab?.pendingHighlight = model.searchQuery
                                model.navigate(to: hit.path)
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
                            if let t = entry.targets.first { model.navigate(to: t) }
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
        }
    }

    private var filteredIndex: [CHMIndexEntry] {
        let all = model.document?.indexEntries ?? []
        guard !state.indexQuery.isEmpty else { return all }
        return all.filter { $0.keyword.localizedCaseInsensitiveContains(state.indexQuery) }
    }
}

// MARK: - 目录树

/// 树节点包装:为 CHMTocItem 提供稳定 id 与可选子节点。
struct TOCTreeNode: Identifiable {
    let item: CHMTocItem
    let children: [TOCTreeNode]?   // nil = 叶子

    init(_ item: CHMTocItem) {
        self.item = item
        self.children = item.children.isEmpty ? nil : item.children.map(TOCTreeNode.init)
    }

    var id: String { (item.local ?? "") + "|" + item.title }
}

/// 递归目录行:箭头控制展开/收起(持久化),标题点击导航。
struct TOCNodeView: View {
    let node: TOCTreeNode
    @ObservedObject var model: AppModel
    let depth: Int

    private var expanded: Bool { model.tocExpanded.contains(node.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if node.children != nil {
                    // 用 Button 而非 Image+手势:保证命中优先级高于整行点按,且有 AXPress
                    Button { model.toggleTOCExpanded(node.id) } label: {
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
                Image(systemName: node.children == nil ? "doc.text" : "book.closed")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Text(node.item.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 14)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture {
                if let local = node.item.local {
                    // 点标题=导航(含既有 local 又有 children 的节点)
                    model.navigate(to: local)
                } else if node.children != nil {
                    // 纯文件夹节点:点标题只切换展开
                    model.toggleTOCExpanded(node.id)
                }
            }
            .contextMenu {
                if let local = node.item.local {
                    Button("在新标签页打开") { model.openInNewTab(local) }
                }
            }
            if expanded, let children = node.children {
                ForEach(children) { child in
                    TOCNodeView(node: child, model: model, depth: depth + 1)
                }
            }
        }
    }
}
