import AppKit
import PDFKit
import WebKit

struct PDFCreationClipboard {
    enum Content { case pdf(Data), image(Data), richText(Data), html(String), text(String) }
    var content: Content
    var summary: String

    @MainActor static func read(_ pasteboard: NSPasteboard = .general) -> Self? {
        if let data = pasteboard.data(forType: .pdf), let pdf = PDFDocument(data: data), !pdf.isLocked, pdf.pageCount > 0 {
            return Self(content: .pdf(data), summary: "PDF · \(pdf.pageCount) 页")
        }
        if let image = pasteboard.readObjects(forClasses: [NSImage.self])?.first as? NSImage, let data = image.tiffRepresentation {
            return Self(content: .image(data), summary: "图片 · \(Int(image.size.width)) × \(Int(image.size.height))")
        }
        if let data = pasteboard.data(forType: .rtf), let value = NSAttributedString(rtf: data, documentAttributes: nil), !value.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Self(content: .richText(data), summary: "富文本 · \(value.length) 字符")
        }
        if let html = pasteboard.string(forType: .html), !html.isEmpty {
            return Self(content: .html(html), summary: "HTML 内容")
        }
        if let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Self(content: .text(text), summary: "文本 · \(text.count) 字符")
        }
        return nil
    }

    func pdf() throws -> Data {
        let document: PDFDocument
        switch content {
        case .pdf(let data): return data
        case .image(let data):
            guard let image = NSImage(data: data), let page = PDFPage(image: image) else { throw FolioError(message: "剪贴板图片无法读取") }
            document = PDFDocument(); document.insert(page, at: 0)
        case .richText(let data):
            guard let text = NSAttributedString(rtf: data, documentAttributes: nil) else { throw FolioError(message: "剪贴板富文本无法读取") }
            document = try TextImport.pdf(from: text)
        case .html(let text): document = try RichTextDocument(text, format: .html).pdf()
        case .text(let text): document = try RichTextDocument(text, format: .plain).pdf()
        }
        return try document.dataRepresentation().unwrap("剪贴板内容转换失败")
    }
}

@MainActor final class PDFWebCreator: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Data, Error>?
    private var timeout: Task<Void, Never>?
    private var options = PDFCreationOptions()
    private var paged = true

    func create(url: URL, options: PDFCreationOptions, paged: Bool) async throws -> Data {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw FolioError(message: "请输入完整的 http 或 https 网页地址") }
        self.options = options; self.paged = paged
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
                let view = WKWebView(frame: CGRect(x: 0, y: 0, width: options.width-options.left-options.right, height: options.height), configuration: configuration)
                self.webView = view; view.navigationDelegate = self
                view.load(URLRequest(url: url, timeoutInterval: 45))
                self.timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                    self?.finish(.failure(FolioError(message: "网页载入超时，请检查网络或换一个网页后重试")))
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) } }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { [weak self] in
            guard let self, self.continuation != nil else { return }
            do {
                let value = try await webView.evaluateJavaScript("Math.max(document.body ? document.body.scrollHeight : 0, document.documentElement.scrollHeight)")
                let height = (value as? NSNumber)?.doubleValue ?? options.height
                guard height.isFinite, height > 0, height <= 72_000 else { throw FolioError(message: "网页过长，请先缩小网页内容范围") }
                let config = WKPDFConfiguration()
                config.rect = CGRect(x: 0, y: 0, width: webView.bounds.width, height: height)
                let raw: Data = try await withCheckedThrowingContinuation { result in webView.createPDF(configuration: config) { result.resume(with: $0) } }
                guard self.continuation != nil else { return }
                let options = self.options
                let data = self.paged ? try await Task.detached { try PDFCreationService.paginate(raw, options: options) }.value : raw
                self.finish(.success(data))
            } catch { self.finish(.failure(error)) }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(["http", "https", "about"].contains(navigationAction.request.url?.scheme ?? "") ? .allow : .cancel)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(FolioError(message: "网页渲染中断，请重试"))) }
    private func finish(_ result: Result<Data, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel(); timeout = nil
        webView?.navigationDelegate = nil; webView?.stopLoading(); webView = nil
        continuation.resume(with: result)
    }
}
