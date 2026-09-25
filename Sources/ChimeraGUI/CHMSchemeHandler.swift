import WebKit
import Foundation
import ChimeraCore

/// chm:// 自定义协议处理器:WKWebView 的所有资源请求(HTML/图片/CSS/JS)
/// 直接从 CHM 容器按需读取,不做任何磁盘解压。
final class CHMSchemeHandler: NSObject, WKURLSchemeHandler {

    enum SchemeError: Error { case badRequest }

    /// 当前文档容器的惰性提供者(文档未打开时为 nil)。
    let provider: () -> CHMContainer?

    init(provider: @escaping () -> CHMContainer?) {
        self.provider = provider
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let container = provider(),
              let url = task.request.url,
              url.scheme?.lowercased() == "chm" else {
            task.didFailWithError(SchemeError.badRequest)
            return
        }

        let rawPath = url.path
        let entryPath = rawPath.hasPrefix("/") ? rawPath : "/" + rawPath

        do {
            var data: Data
            var mime: String

            if let entry = container.entry(at: entryPath), !entry.isDirectory {
                data = try container.read(entryPath)   // LZX 惰性解压
                mime = CHMMimeType.forPath(entryPath)
            } else {
                // 缺失条目:页面请求给 404 提示页;非页面请求(图片/CSS/JS 等)
                // 直接报错,由 WebView 按 broken image 处理,不把 HTML 当图片解码
                guard CHMMimeType.forPath(entryPath) == "text/html" else {
                    task.didFailWithError(NSError(domain: NSURLErrorDomain,
                                                  code: NSURLErrorFileDoesNotExist))
                    return
                }
                data = Data("""
                <html><body style="font-family:-apple-system;padding:2em;color:#666">
                <h3>404</h3><p>CHM 内未找到条目:<code>\(entryPath)</code></p>
                </body></html>
                """.utf8)
                mime = "text/html"
            }

            // 文本类:按解码链转 UTF-8。
            // 注意:mimeType 只能是纯类型("text/html"),charset 必须走 textEncodingName,
            // 否则 WebKit 识别不了而按纯文本展示源码(此缺陷曾导致正文显示为 HTML 源码)。
            var encodingName: String? = nil
            if mime == "text/html" || mime == "text/css" {
                let lcid = ((try? container.systemInfo()) ?? nil)?.lcid
                let declared = CHMCharset.declared(in: data)
                let text = CHMTextDecoder(lcid: lcid, declaredCharset: declared).decode(data)
                data = Data(text.utf8)
                encodingName = "utf-8"
            }

            let response = URLResponse(
                url: url,
                mimeType: mime,
                expectedContentLength: data.count,
                textEncodingName: encodingName
            )
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        } catch {
            task.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // 同步服务,无需取消逻辑
    }
}
