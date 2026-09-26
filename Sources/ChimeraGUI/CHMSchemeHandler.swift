import WebKit
import Foundation
import ChimeraCore

/// chm:// 自定义协议处理器:WKWebView 的所有资源请求(HTML/图片/CSS/JS)
/// 直接从 CHM 容器按需读取,不做任何磁盘解压。
///
/// P0-1:WebKit 在主线程调 start,此处若同步做 entry 解析 + 读取
/// (pread + LZX 解压)会阻塞主线程;每个子资源都卡一次。
/// 现改为:实际工作派发到私有串行后台队列,WebKit 回调
/// (didReceive/didFinish/didFailWithError)全部回主线程;
/// 大体积二进制条目按 64KB 块流式回传。
final class CHMSchemeHandler: NSObject, WKURLSchemeHandler {

    enum SchemeError: Error { case badRequest }

    /// 当前文档容器的惰性提供者(文档未打开时为 nil)。
    let provider: () -> CHMContainer?

    /// 资源服务队列:entry 解析、pread、LZX 解压、文本重编码都在此执行,
    /// 主线程立即返回。串行:同容器请求按序,不与 chmlib 句柄并发争抢。
    private let workQueue = DispatchQueue(label: "Chimera.CHMSchemeHandler", qos: .userInitiated)

    /// 活跃 task 的停止标记表;仅在主线程访问
    /// (start/stop 由 WebKit 在主线程调,完成回调也回主线程)。
    private var activeGuards: [ObjectIdentifier: TaskGuard] = [:]

    /// 每 task 的停止标记(P0-1 stop 契约)。
    /// WebKit 调 stop 后绝不能再对该 task 发任何回调,否则 WebKit crash:
    /// stop 置位,后台队列上的工作据此提前退出,每个主线程回调块执行前复查。
    private final class TaskGuard {
        private let lock = NSLock()
        private var stopped = false

        var isStopped: Bool {
            lock.lock(); defer { lock.unlock() }
            return stopped
        }

        func markStopped() {
            lock.lock(); defer { lock.unlock() }
            stopped = true
        }
    }

    init(provider: @escaping () -> CHMContainer?) {
        self.provider = provider
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let container = provider(),
              let url = task.request.url,
              url.scheme?.lowercased() == "chm" else {
            // start 本身在主线程被调,直接同步报错即可
            task.didFailWithError(SchemeError.badRequest)
            return
        }

        let guard_ = TaskGuard()
        activeGuards[ObjectIdentifier(task)] = guard_

        let rawPath = url.path
        let entryPath = rawPath.hasPrefix("/") ? rawPath : "/" + rawPath

        workQueue.async {
            self.serve(task: task, url: url, entryPath: entryPath,
                       container: container, taskGuard: guard_)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // 置位并移除标记:此后后台工作提前退出、主线程回调块全部静默
        if let g = activeGuards.removeValue(forKey: ObjectIdentifier(urlSchemeTask)) {
            g.markStopped()
        }
    }

    // MARK: - 后台服务(workQueue 上执行)

    private func serve(task: WKURLSchemeTask, url: URL, entryPath: String,
                       container: CHMContainer, taskGuard: TaskGuard) {
        if let entry = container.entry(at: entryPath), !entry.isDirectory {
            let mime = CHMMimeType.forPath(entryPath)
            if mime == "text/html" || mime == "text/css" {
                serveText(task, url, entry, mime, container, taskGuard)
            } else {
                serveBinary(task, url, entry, mime, container, taskGuard)
            }
        } else if CHMMimeType.forPath(entryPath) == "text/html" {
            // 缺失的页面条目:给 404 提示页;路径经 HTML 转义(P2-13),
            // 防止请求路径里的标记被当 HTML 解析
            let data = Data("""
            <html><body style="font-family:-apple-system;padding:2em;color:#666">
            <h3>404</h3><p>CHM 内未找到条目:<code>\(CHMHTMLEscape.escape(entryPath))</code></p>
            </body></html>
            """.utf8)
            respond(task, taskGuard, completion: true) { t in
                t.didReceive(URLResponse(url: url, mimeType: "text/html",
                                         expectedContentLength: data.count,
                                         textEncodingName: "utf-8"))
                t.didReceive(data)
                t.didFinish()
            }
        } else {
            // 缺失的非页面条目(图片/CSS/JS 等)直接报错,
            // 由 WebView 按 broken image 处理,不把 HTML 当图片解码
            fail(task, taskGuard,
                 NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist))
        }
    }

    /// 文本条目(html/css):需整体解码(BOM/charset 嗅探三级回退)后
    /// 重编码 UTF-8,无法分块,保持整块语义。
    private func serveText(_ task: WKURLSchemeTask, _ url: URL, _ entry: CHMEntry,
                           _ mime: String, _ container: CHMContainer, _ taskGuard: TaskGuard) {
        do {
            var data = try container.read(entry: entry)   // LZX 惰性解压
            // 注意:mimeType 只能是纯类型("text/html"),charset 必须走 textEncodingName,
            // 否则 WebKit 识别不了而按纯文本展示源码(此缺陷曾导致正文显示为 HTML 源码)。
            let lcid = ((try? container.systemInfo()) ?? nil)?.lcid
            let declared = CHMCharset.declared(in: data)
            let text = CHMTextDecoder(lcid: lcid, declaredCharset: declared).decode(data)
            data = Data(text.utf8)
            if taskGuard.isStopped { return }   // 解压期间已被 stop,免再排队

            let dataCopy = data
            respond(task, taskGuard, completion: true) { t in
                t.didReceive(URLResponse(url: url, mimeType: mime,
                                         expectedContentLength: dataCopy.count,
                                         textEncodingName: "utf-8"))
                t.didReceive(dataCopy)
                t.didFinish()
            }
        } catch {
            fail(task, taskGuard, error)
        }
    }

    /// 二进制条目(图片等):64KB 块流式读取与回传,
    /// expectedContentLength 用条目原始 length(进度指示)。
    private func serveBinary(_ task: WKURLSchemeTask, _ url: URL, _ entry: CHMEntry,
                             _ mime: String, _ container: CHMContainer, _ taskGuard: TaskGuard) {
        let chunkSize: UInt64 = 64 * 1024
        let response = URLResponse(url: url, mimeType: mime,
                                   expectedContentLength: Int(clamping: entry.length),
                                   textEncodingName: nil)
        // 先回 response;主队列 FIFO,保证 response → 各块 → finish 顺序
        respond(task, taskGuard) { t in t.didReceive(response) }

        var offset: UInt64 = 0
        while offset < entry.length {
            if taskGuard.isStopped { return }   // 已取消,停止读盘
            let upper = min(offset + chunkSize, entry.length)
            let chunk: Data
            do {
                chunk = try container.read(entry: entry, range: offset..<upper)
            } catch {
                fail(task, taskGuard, error)
                return
            }
            respond(task, taskGuard) { t in t.didReceive(chunk) }
            offset = upper
        }

        respond(task, taskGuard, completion: true) { t in t.didFinish() }
    }

    // MARK: - 主线程回调

    /// 把一批回调派回主线程执行;执行前复查停止标记,
    /// stop 之后绝不再触碰 task(WebKit 契约,违者 crash)。
    /// completion:本块为该 task 的最终回调,顺手清理标记表。
    private func respond(_ task: WKURLSchemeTask, _ taskGuard: TaskGuard,
                         completion: Bool = false,
                         _ body: @escaping (WKURLSchemeTask) -> Void) {
        DispatchQueue.main.async {
            guard !taskGuard.isStopped else { return }
            body(task)
            if completion {
                self.activeGuards[ObjectIdentifier(task)] = nil
            }
        }
    }

    private func fail(_ task: WKURLSchemeTask, _ taskGuard: TaskGuard, _ error: Error) {
        if taskGuard.isStopped { return }
        DispatchQueue.main.async {
            guard !taskGuard.isStopped else { return }
            task.didFailWithError(error)
            self.activeGuards[ObjectIdentifier(task)] = nil
        }
    }
}
