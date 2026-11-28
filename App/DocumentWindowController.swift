import AppKit
import PDFKit
import UniformTypeIdentifiers
import WebKit

final class FileDropView: NSView {
  var openFiles: (([URL]) -> Void)?
  override init(frame: NSRect) {
    super.init(frame: frame)
    registerForDraggedTypes([.fileURL])
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let urls =
      sender.draggingPasteboard.readObjects(
        forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    guard !urls.isEmpty else { return false }
    openFiles?(urls)
    return true
  }
}
private final class ViewerMessage: NSObject, WKScriptMessageHandler {
  weak var owner: DocumentWindowController?
  func userContentController(
    _ controller: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard message.frameInfo.isMainFrame, let data = message.body as? [String: Any] else { return }
    MainActor.assumeIsolated { owner?.updateState(data) }
  }
}

// Route document gestures before WebKit handles its own scrolling or magnification.
final class ViewerWindow: NSWindow {
  var turnPage: ((Int) -> Bool)?
  var magnifyDocument: ((Double, NSPoint) -> Bool)?
  override func sendEvent(_ event: NSEvent) {
    if attachedSheet == nil {
      if event.type == .keyDown,
        event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
        !((firstResponder as? NSTextView)?.isFieldEditor ?? false)
      {
        let direction: Int
        switch event.keyCode {
        case 123, 126: direction = -1
        case 124, 125: direction = 1
        default: direction = 0
        }
        if direction != 0, turnPage?(direction) == true { return }
      }
      if event.type == .magnify,
        magnifyDocument?(Double(event.magnification), event.locationInWindow) == true
      {
        return
      }
    }
    super.sendEvent(event)
  }
}

@MainActor
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate {
  let url: URL
  private let assets: URL
  private(set) var renderer: WebRenderer?
  private(set) var isClosed = false
  private(set) var ready = false
  private(set) var pageCount = 0
  private var scale = 1.0
  private var current = 1
  private var generation = 0
  private var exporter: DocumentPDFExporter?
  private var exportTask: Task<Void, Never>?
  private var pendingScript: Task<Void, Never>?
  var onClose: (() -> Void)?
  var onRetry: (() -> Void)?
  var openFiles: (([URL]) -> Void)?
  private let content = FileDropView(frame: .zero)
  private let body = NSView()
  private let status = NSTextField(wrappingLabelWithString: "")
  private let page = NSTextField(string: "1")
  private let total = NSTextField(labelWithString: "/ 0쪽")
  let search = NSSearchField()
  private let findRow = NSStackView()
  var isSearchVisible: Bool { !findRow.isHidden }
  private let results = NSTextField(labelWithString: "")
  private var actions: [NSControl] = []
  private let retry = NSButton(title: "다시 시도", target: nil, action: nil)
  private let cancelOutput = NSButton(title: "출력 취소", target: nil, action: nil)
  init(url: URL, assets: URL) {
    self.url = url
    self.assets = assets
    let window = ViewerWindow(
      contentRect: NSRect(x: 0, y: 0, width: 960, height: 820),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    super.init(window: window)
    window.turnPage = { [weak self] in self?.turnPage($0) ?? false }
    window.magnifyDocument = { [weak self] in self?.magnify($0, at: $1) ?? false }
    window.title = url.lastPathComponent
    window.representedURL = url
    window.delegate = self
    window.minSize = NSSize(width: 780, height: 450)
    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    window.contentView = content
    content.openFiles = { [weak self] in self?.openFiles?($0) }
    page.alignment = .center
    page.target = self
    page.action = #selector(goToPage)
    page.widthAnchor.constraint(equalToConstant: 48).isActive = true
    page.setAccessibilityLabel("이동할 쪽")
    let row = NSStackView(views: [
      button("이전", #selector(previousPage)), page, total, button("다음", #selector(nextPage)),
      button("−", #selector(zoomOut)), button("+", #selector(zoomIn)),
      button("너비 맞춤", #selector(fitWidth)), button("검색", #selector(toggleSearch)),
      button("인쇄…", #selector(printDocument)), button("PDF 저장…", #selector(savePDF)),
    ])
    row.spacing = 8
    row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
    search.placeholderString = "문서에서 찾기"
    search.delegate = self
    search.target = self
    search.action = #selector(findNext)
    search.sendsSearchStringImmediately = false
    search.sendsWholeSearchString = true
    search.widthAnchor.constraint(equalToConstant: 260).isActive = true
    for view in [
      search, button("이전 결과", #selector(findPrevious)), button("다음 결과", #selector(findNext)),
      results, button("닫기", #selector(hideSearch)),
    ] { findRow.addArrangedSubview(view) }
    findRow.isHidden = true
    findRow.spacing = 8
    findRow.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 8, right: 12)
    actions += [search, page]
    retry.target = self
    retry.action = #selector(retryLoad)
    retry.isHidden = true
    cancelOutput.target = self
    cancelOutput.action = #selector(cancelExport)
    cancelOutput.isHidden = true
    let statusRow = NSStackView(views: [status, retry, cancelOutput])
    statusRow.spacing = 8
    statusRow.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
    status.setContentHuggingPriority(.defaultLow, for: .horizontal)
    status.setAccessibilityRole(.staticText)
    let stack = NSStackView(views: [row, findRow, statusRow, body])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 0
    content.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      stack.topAnchor.constraint(equalTo: content.topAnchor),
      stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      body.widthAnchor.constraint(equalTo: stack.widthAnchor),
      statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])
    body.setContentHuggingPriority(.defaultLow, for: .vertical)
    window.center()
    setQueued()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
  private func button(_ title: String, _ action: Selector) -> NSButton {
    let button = NSButton(title: title, target: self, action: action)
    button.bezelStyle = .rounded
    button.setAccessibilityLabel(title)
    actions.append(button)
    return button
  }
  func setQueued() {
    ready = false
    status.stringValue = "문서 열기 대기 중…"
    refreshControls()
  }
  private func refreshControls() {
    actions.forEach { $0.isEnabled = ready && exporter == nil }
    cancelOutput.isHidden = exporter == nil
  }
  func load(completion: @escaping () -> Void) {
    generation += 1
    let request = generation
    pendingScript?.cancel()
    disposeRenderer()
    ready = false
    retry.isHidden = true
    status.stringValue = "문서를 읽는 중…"
    refreshControls()
    let renderer = WebRenderer(assets: assets)
    self.renderer = renderer
    let handler = ViewerMessage()
    handler.owner = self
    renderer.webView.configuration.userContentController.add(handler, name: "viewerState")
    renderer.runtimeFailure = { [weak self] error in self?.fail(error) }
    renderer.webView.openFiles = { [weak self] in self?.openFiles?($0) }
    let web = renderer.webView
    web.translatesAutoresizingMaskIntoConstraints = false
    body.addSubview(web)
    NSLayoutConstraint.activate([
      web.leadingAnchor.constraint(equalTo: body.leadingAnchor),
      web.trailingAnchor.constraint(equalTo: body.trailingAnchor),
      web.topAnchor.constraint(equalTo: body.topAnchor),
      web.bottomAnchor.constraint(equalTo: body.bottomAnchor),
    ])
    renderer.render(url) { [weak self] result in
      defer { completion() }
      guard let self, !self.isClosed, self.generation == request else { return }
      switch result {
      case .failure(let error): self.fail(error)
      case .success(let info):
        self.pageCount = info["pages"] as? Int ?? 0
        self.ready = true
        self.scale = 1
        self.current = 1
        self.status.stringValue = "\(self.pageCount)쪽 · 읽기 전용"
        if (info["imageFailures"] as? Int ?? 0) > 0 {
          self.status.stringValue += " · 일부 이미지를 표시하지 못했습니다"
        }
        self.refreshControls()
        self.script("return window.documentTools.enable()")
      }
    }
  }
  private func disposeRenderer() {
    renderer?.webView.configuration.userContentController.removeScriptMessageHandler(
      forName: "viewerState")
    renderer?.dispose()
    renderer?.webView.removeFromSuperview()
  }
  private func fail(_ error: Error) {
    guard !isClosed else { return }
    ready = false
    cancelExport()
    status.stringValue = error.localizedDescription
    retry.isHidden = false
    refreshControls()
  }
  func updateState(_ data: [String: Any]) {
    guard ready, !isClosed else { return }
    current = data["page"] as? Int ?? current
    scale = data["scale"] as? Double ?? scale
    if window?.firstResponder !== page.currentEditor() { page.stringValue = String(current) }
    total.stringValue = "/ \(pageCount)쪽"
    results.stringValue = searchSummary(data)
  }
  private func searchSummary(_ data: [String: Any]) -> String {
    if search.stringValue.isEmpty { return "" }
    let count = data["matches"] as? Int ?? 0
    if count == 0 { return "결과 없음" }
    let selected = data["selected"] as? Int ?? 0
    let limited = data["limited"] as? Bool == true ? " (최대 표시)" : ""
    return "\(selected) / \(count)\(limited)"
  }
  private func script(_ code: String, arguments: [String: Any] = [:]) {
    guard ready, let web = renderer?.webView else { return }
    let request = generation
    pendingScript?.cancel()
    pendingScript = Task { [weak self] in
      do {
        let value = try await web.documentScript(code, arguments: arguments)
        try Task.checkCancellation()
        if let self, !self.isClosed, self.generation == request, let data = value as? [String: Any]
        {
          self.updateState(data)
        }
      } catch is CancellationError {} catch {
        if let self, !self.isClosed, self.generation == request {
          self.status.stringValue = "문서 동작을 처리하지 못했습니다."
        }
      }
    }
  }
  @objc func previousPage() { navigate(max(1, current - 1)) }
  @objc func nextPage() { navigate(min(pageCount, current + 1)) }
  private func navigate(_ n: Int) {
    script("return window.documentTools.go(page)", arguments: ["page": n])
  }
  @objc func goToPage() {
    guard let n = Int(page.stringValue), n > 0, n <= pageCount else {
      page.stringValue = String(current)
      NSSound.beep()
      return
    }
    navigate(n)
  }
  @objc func zoomIn() { zoom(to: scale + 0.25) }
  @objc func zoomOut() { zoom(to: scale - 0.25) }
  private func zoom(to value: Double) {
    script("return window.documentTools.zoom(value)", arguments: ["value": value])
  }
  @objc func fitWidth() { script("return window.documentTools.zoom(1)") }
  @objc func toggleSearch() {
    if isSearchVisible { hideSearch() } else { focusSearch() }
  }
  @objc func focusSearch() {
    findRow.isHidden = false
    window?.contentView?.layoutSubtreeIfNeeded()
    window?.makeFirstResponder(search)
  }
  @objc func hideSearch() { cancelOperation(nil) }
  func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector)
    -> Bool
  {
    if commandSelector == #selector(cancelOperation(_:)) {
      hideSearch()
      return true
    }
    return false
  }
  @discardableResult func turnPage(_ direction: Int) -> Bool {
    guard ready, exporter == nil, let web = renderer?.webView else { return false }
    web.callAsyncJavaScript(
      "return documentTools.step(direction)", arguments: ["direction": direction], in: nil,
      in: .page, completionHandler: nil)
    return true
  }
  @discardableResult func magnify(_ delta: Double, at windowPoint: NSPoint? = nil) -> Bool {
    guard ready, exporter == nil, delta.isFinite, let web = renderer?.webView else { return false }
    let point =
      windowPoint.map { web.convert($0, from: nil) }
      ?? NSPoint(x: web.bounds.midX, y: web.bounds.midY)
    guard web.bounds.width > 0, web.bounds.height > 0, web.bounds.contains(point) else {
      return false
    }
    let x = (point.x - web.bounds.minX) / web.bounds.width
    let y = (point.y - web.bounds.minY) / web.bounds.height
    web.callAsyncJavaScript(
      "return documentTools.zoomBy(delta, x, y)",
      arguments: ["delta": delta, "x": x, "y": web.isFlipped ? y : 1 - y], in: nil, in: .page,
      completionHandler: nil)
    return true
  }
  @objc func findNext() { find(direction: 1) }
  @objc func findPrevious() { find(direction: -1) }
  private func find(direction: Int) {
    script(
      "return window.documentTools.search(query,direction)",
      arguments: ["query": search.stringValue, "direction": direction])
  }
  func controlTextDidChange(_ obj: Notification) {
    if search.stringValue.isEmpty { clearSearch() }
  }
  private func clearSearch() {
    script("window.documentTools.clearSearch();return window.documentTools.state()")
  }
  override func cancelOperation(_ sender: Any?) {
    findRow.isHidden = true
    search.stringValue = ""
    clearSearch()
    window?.makeFirstResponder(renderer?.webView)
  }
  @objc func retryLoad() { onRetry?() }
  @objc func cancelExport() {
    exportTask?.cancel()
    exporter?.cancel()
  }
  @objc func savePDF() {
    guard ready, exporter == nil, let window else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.pdf]
    panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + ".pdf"
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let destination = panel.url else { return }
      self?.performExport { [weak self] data in
        guard let self else { return }
        try DocumentPDFExporter.write(data, to: destination, original: self.url)
      }
    }
  }
  @objc func printDocument() {
    performExport { [weak self] data in
      guard let self, let window = self.window, let pdf = PDFDocument(data: data),
        let operation = pdf.printOperation(
          for: NSPrintInfo.shared, scalingMode: .pageScaleDownToFit, autoRotate: true)
      else { throw DocumentExportError.invalidPage }
      operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }
  }
  private func performExport(_ consume: @escaping (Data) throws -> Void) {
    guard ready, exporter == nil, let web = renderer?.webView else { return }
    let exporter = DocumentPDFExporter()
    self.exporter = exporter
    refreshControls()
    exporter.progress = { [weak self] done, total in
      self?.status.stringValue = "PDF 준비 중 \(done)/\(total)쪽"
    }
    exportTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.exporter = nil
        self.exportTask = nil
        self.refreshControls()
      }
      do {
        let data = try await exporter.export(from: web, pageCount: self.pageCount)
        guard !self.isClosed else { return }
        try consume(data)
        self.status.stringValue = "출력 준비 완료 · \(self.pageCount)쪽"
      } catch is CancellationError {
        if !self.isClosed && self.ready { self.status.stringValue = "출력을 취소했습니다." }
      } catch {
        if !self.isClosed && self.ready { self.status.stringValue = error.localizedDescription }
      }
    }
  }
  func windowWillClose(_ notification: Notification) {
    isClosed = true
    ready = false
    generation += 1
    pendingScript?.cancel()
    cancelExport()
    disposeRenderer()
    renderer = nil
    onClose?()
    onClose = nil
    onRetry = nil
  }
}
