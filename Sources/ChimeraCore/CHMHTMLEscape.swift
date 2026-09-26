import Foundation

/// HTML 转义小助手(P2-13)。
///
/// 供把非受控字符串(如 chm:// 请求路径)插入 HTML 文本/属性上下文前转义,
/// 覆盖 HTML 五个语法敏感字符,防止 404 提示页等生成内容被注入标记。
/// 注意本转义**不幂等**:输入已含实体(如 `a&amp;b`)会再次转义
/// (`a&amp;amp;b`),这正是正确语义——实体的字面文本就该显示为实体本身。
public enum CHMHTMLEscape {
    /// HTML 文本/属性上下文最小转义:`&` `<` `>` `"` `'`。
    /// 其余字符(含中文等非 ASCII)原样保留。
    public static func escape(_ s: String) -> String {
        // 快路径:无敏感字符时直接返回原串,避免分配
        guard s.unicodeScalars.contains(where: { "&<>\"'".unicodeScalars.contains($0) }) else {
            return s
        }
        var out = String()
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
