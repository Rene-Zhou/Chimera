import Foundation

/// CHM 内部路径语义的相对链接解析(纯字符串,不涉 URL 编码)。
public enum CHMPath {

    /// 将 relative 解析到 base 所在目录,返回规范化绝对路径(以 "/" 开头)。
    ///
    /// - base 以 "/" 结尾视为目录;否则视为文件(取其目录部分)
    /// - 剥离锚点(#)与查询串(?);纯锚点/空 → base 原样
    /// - 折叠 "./"、"../" 与重复斜杠;".." 越顶钳制到根
    public static func resolve(_ relative: String, base: String) -> String {
        var rel = relative
        if let idx = rel.firstIndex(of: "#") { rel = String(rel[..<idx]) }
        if let idx = rel.firstIndex(of: "?") { rel = String(rel[..<idx]) }
        rel = rel.trimmingCharacters(in: .whitespaces)

        if rel.isEmpty { return normalized(base) }
        if rel.hasPrefix("/") { return normalized(rel) }

        let dir: String
        if base.hasSuffix("/") {
            dir = base
        } else if let slash = base.lastIndex(of: "/") {
            dir = String(base[...slash])
        } else {
            dir = "/"
        }
        return normalized(dir + rel)
    }

    /// 折叠路径段:去空段与 ".",消费 "..",越顶钳制。
    static func normalized(_ path: String) -> String {
        var out: [Substring] = []
        for seg in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch seg {
            case ".": continue
            case "..": if !out.isEmpty { out.removeLast() }
            default: out.append(seg)
            }
        }
        return "/" + out.joined(separator: "/")
    }

    // MARK: - 外链回投

    /// 将抓取源站的绝对 http(s) 链接回投为容器内页面。
    ///
    /// 抓取站生成的 CHM 常把站内交叉引用写成源站绝对 URL(如
    /// `https://host/topics/…/动作.htm#Attack`)。按"末段文件名(百分号解码,
    /// 大小写不敏感)"在 filenameIndex(文件名小写 → 内部路径)中查找;命中返回
    /// 内部路径与原锚点,未命中返回 nil(调用方走外链兜底)。
    public static func mapExternalToInternal(
        _ urlString: String, filenameIndex: [String: String]
    ) -> (path: String, fragment: String?)? {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        let last = url.lastPathComponent  // URL 已做百分号解码
        guard !last.isEmpty else { return nil }
        guard let path = filenameIndex[last.lowercased()] else { return nil }
        return (path, url.fragment)
    }
}

/// 扩展名 → MIME 类型。
public enum CHMMimeType {
    public static func forPath(_ path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "js": return "text/javascript"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "bmp": return "image/bmp"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "txt": return "text/plain"
        default: return "application/octet-stream"
        }
    }
}
