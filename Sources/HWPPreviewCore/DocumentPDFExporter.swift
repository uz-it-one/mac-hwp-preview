import AppKit
import PDFKit
import WebKit

public enum DocumentExportError: Error, LocalizedError {
  case invalidPage, outputLimit, originalDestination
  public var errorDescription: String? {
    switch self {
    case .invalidPage: return "문서 페이지를 PDF로 만들지 못했습니다."
    case .outputLimit: return "PDF 출력 한도(100 MiB)를 초과했습니다."
    case .originalDestination: return "원본 문서와 같은 위치에는 PDF를 저장할 수 없습니다."
    }
  }
}

// WebKit callbacks may arrive after cancellation or process termination.
@MainActor private final class WebOperation<Value> {
  private var continuation: CheckedContinuation<Value, Error>?
  private var timer: Timer?
  private var cancelled = false
  func finish(_ result: Result<Value, Error>) {
    timer?.invalidate()
    timer = nil
    let pending = continuation
    continuation = nil
    pending?.resume(with: result)
  }
  func cancel() {
    cancelled = true
    finish(.failure(CancellationError()))
  }
  func run(_ start: (@escaping @MainActor @Sendable (Result<Value, Error>) -> Void) -> Void)
    async throws -> Value
  {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { pending in
        guard !cancelled else {
          pending.resume(throwing: CancellationError())
          return
        }
        continuation = pending
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
          MainActor.assumeIsolated { self?.finish(.failure(PreviewFailure.timeout)) }
        }
        start { [self] result in finish(result) }
      }
    } onCancel: {
      Task { @MainActor [self] in cancel() }
    }
  }
}

extension WKWebView {
  @MainActor public func documentScript(_ script: String, arguments: [String: Any] = [:])
    async throws -> Any
  {
    try await WebOperation<Any>().run { completion in
      callAsyncJavaScript(
        script, arguments: arguments, in: nil, in: .page, completionHandler: completion)
    }
  }
}

/// Captures sanitized SVG pages at a fixed scale, independent of the on-screen viewer.
@MainActor public final class DocumentPDFExporter: NSObject, WKNavigationDelegate {
  private let output: WKWebView
  private var navigation: CheckedContinuation<Void, Error>?
  private var timeout: Timer?
  private var cancelled = false
  public var progress: ((Int, Int) -> Void)?
  public override init() {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    output = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 1100), configuration: config)
    super.init()
    output.navigationDelegate = self
  }
  public func cancel() {
    cancelled = true
    output.stopLoading()
    finishNavigation(.failure(CancellationError()))
  }
  private func checkCancellation() throws {
    try Task.checkCancellation()
    if cancelled { throw CancellationError() }
  }
  private func finishNavigation(_ result: Result<Void, Error>) {
    timeout?.invalidate()
    timeout = nil
    let pending = navigation
    navigation = nil
    pending?.resume(with: result)
  }
  public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    finishNavigation(.success(()))
  }
  public func webView(
    _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
  ) { finishNavigation(.failure(error)) }
  public func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) { finishNavigation(.failure(error)) }
  public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    finishNavigation(.failure(PreviewFailure.engineFailed))
  }
  public func export(from source: WKWebView, pageCount: Int) async throws -> Data {
    guard pageCount > 0, pageCount <= 500 else { throw DocumentExportError.invalidPage }
    let combined = NSMutableData()
    guard let consumer = CGDataConsumer(data: combined as CFMutableData),
      let context = CGContext(consumer: consumer, mediaBox: nil, nil)
    else { throw DocumentExportError.invalidPage }
    var completed = false
    defer {
      if !completed { context.closePDF() }
      output.stopLoading()
      timeout?.invalidate()
    }
    var capturedBytes = 0
    for index in 0..<pageCount {
      try checkCancellation()
      let raw = try await source.documentScript(
        "return window.documentTools.pageData(index)", arguments: ["index": index])
      guard let page = raw as? [String: Any], let svg = page["source"] as? String,
        let width = page["width"] as? Double, let height = page["height"] as? Double,
        width.isFinite, height.isFinite, width > 0, height > 0, width <= 20000, height <= 20000
      else { throw DocumentExportError.invalidPage }
      output.setFrameSize(NSSize(width: width, height: height))
      let html = """
        <!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'">
        <style>html,body{margin:0;padding:0;background:white;width:\(width)px;height:\(height)px;overflow:hidden}svg{display:block;width:\(width)px;height:\(height)px}</style></head><body>\(svg)</body></html>
        """
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        navigation = continuation
        timeout = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
          MainActor.assumeIsolated {
            self?.output.stopLoading()
            self?.finishNavigation(.failure(PreviewFailure.timeout))
          }
        }
        output.loadHTMLString(html, baseURL: nil)
      }
      _ = try await output.documentScript(
        "await Promise.all([...document.querySelectorAll('svg image')].map(async element=>{const image=new Image();image.src=element.getAttribute('href')||element.getAttributeNS('http://www.w3.org/1999/xlink','href');await image.decode()})); await document.fonts.ready; await new Promise(r=>setTimeout(r,30)); return true"
      )
      try checkCancellation()
      let configuration = WKPDFConfiguration()
      configuration.rect = CGRect(x: 0, y: 0, width: width, height: height)
      let data = try await WebOperation<Data>().run { completion in
        output.createPDF(configuration: configuration, completionHandler: completion)
      }
      capturedBytes += data.count
      guard capturedBytes <= 100 * 1024 * 1024, combined.length <= 100 * 1024 * 1024 else {
        throw DocumentExportError.outputLimit
      }
      guard let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider),
        pdf.numberOfPages == 1, let original = pdf.page(at: 1)
      else { throw DocumentExportError.invalidPage }
      let bounds = original.getBoxRect(.mediaBox)
      var target = CGRect(x: 0, y: 0, width: width * 0.75, height: height * 0.75)
      let box = Data(bytes: &target, count: MemoryLayout<CGRect>.size)
      context.beginPDFPage([kCGPDFContextMediaBox as String: box] as CFDictionary)
      context.saveGState()
      context.scaleBy(x: target.width / bounds.width, y: target.height / bounds.height)
      context.translateBy(x: -bounds.minX, y: -bounds.minY)
      context.drawPDFPage(original)
      context.restoreGState()
      context.endPDFPage()
      progress?(index + 1, pageCount)
    }
    context.closePDF()
    completed = true
    try checkCancellation()
    guard combined.length <= 100 * 1024 * 1024 else { throw DocumentExportError.outputLimit }
    let data = combined as Data
    guard PDFDocument(data: data)?.pageCount == pageCount else {
      throw DocumentExportError.invalidPage
    }
    return data
  }
  public static func write(_ data: Data, to destination: URL, original: URL) throws {
    let target = destination.standardizedFileURL.resolvingSymlinksInPath()
    let source = original.standardizedFileURL.resolvingSymlinksInPath()
    func fileID(_ url: URL) -> NSObject? {
      try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        as? NSObject
    }
    let targetID = fileID(target)
    guard target != source, !(targetID != nil && targetID == fileID(source)),
      target.pathExtension.lowercased() == "pdf"
    else { throw DocumentExportError.originalDestination }
    try data.write(to: destination, options: .atomic)
  }
}
