import AppKit
import PDFKit
import UniformTypeIdentifiers
import WebKit

@main struct ViewerProbe {
  @MainActor static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() {
      throw NSError(domain: "ViewerProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
  }
  @MainActor static func wait(_ condition: () -> Bool) async throws {
    let end = Date().addingTimeInterval(45)
    while !condition() {
      if Date() > end {
        throw NSError(
          domain: "ViewerProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "timed out"])
      }
      try await Task.sleep(nanoseconds: 30_000_000)
    }
  }
  @MainActor static func run() async throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let assets = root.appendingPathComponent(".build/app/HWP Preview.app/Contents/Resources/Web")
    let evidence = root.appendingPathComponent(".build/viewer-evidence")
    let coordinator = DocumentCoordinator(assets: assets)
    let book = root.appendingPathComponent(".build/fixtures/book.hwp")
    let form = root.appendingPathComponent(".build/fixtures/form.hwpx")
    let picture = root.appendingPathComponent(".build/fixtures/image.hwpx")
    coordinator.open([book, form, book])
    try require(coordinator.documents.count == 2, "duplicate document")
    try await wait { coordinator.documents.values.allSatisfy { $0.ready } }
    let a = coordinator.documents[book]!
    let b = coordinator.documents[form]!
    try require(a.pageCount == 2 && b.pageCount == 10, "fixture page counts")
    a.window!.contentView!.layoutSubtreeIfNeeded()
    let content = a.window!.contentView!
    if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
      content.cacheDisplay(in: content.bounds, to: bitmap)
      try bitmap.representation(using: .png, properties: [:])!.write(
        to: evidence.appendingPathComponent("viewer-controls.png"))
    }
    let web = a.renderer!.webView
    try require(!a.isSearchVisible, "search initially hidden")
    let viewerWindow = a.window!
    viewerWindow.makeFirstResponder(web)
    @MainActor func arrow(_ code: UInt16) {
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: viewerWindow.windowNumber, context: nil, characters: "",
        charactersIgnoringModifiers: "",
        isARepeat: false, keyCode: code)!
      viewerWindow.sendEvent(event)
    }
    arrow(125)
    var state = try await web.documentScript("return documentTools.state()") as! [String: Any]
    try require(state["page"] as? Int == 2, "down arrow next page")
    arrow(124)
    state = try await web.documentScript("return documentTools.state()") as! [String: Any]
    try require(state["page"] as? Int == 2, "last page clamp")
    arrow(126)
    state = try await web.documentScript("return documentTools.state()") as! [String: Any]
    try require(state["page"] as? Int == 1, "up arrow previous page")
    arrow(123)
    state = try await web.documentScript("return documentTools.state()") as! [String: Any]
    try require(state["page"] as? Int == 1, "first page clamp")
    a.focusSearch()
    try require(a.isSearchVisible && a.search.currentEditor() != nil, "search reveal and focus")
    arrow(125)
    state = try await web.documentScript("return documentTools.state()") as! [String: Any]
    try require(state["page"] as? Int == 1, "arrows preserve search editing")
    a.hideSearch()
    try require(!a.isSearchVisible, "search close")
    a.toggleSearch()
    try require(a.isSearchVisible, "search button reveal")
    a.toggleSearch()
    try require(!a.isSearchVisible, "search button hide")
    a.magnify(0.2)
    a.magnify(0.2)
    state = try await web.documentScript("return documentTools.state()") as! [String: Any]
    try require(abs((state["scale"] as! Double) - 1.44) < 0.001, "incremental pinch")
    a.magnify(10)
    state = try await web.documentScript("return documentTools.state()") as! [String: Any]
    try require(state["scale"] as? Double == 3, "pinch maximum")
    a.magnify(-0.99)
    state = try await web.documentScript("return documentTools.state()") as! [String: Any]
    try require(state["scale"] as? Double == 0.5, "pinch minimum")
    try require(!a.magnify(.nan), "invalid pinch ignored")
    _ = try await web.documentScript("return documentTools.zoom(1)")
    // Exercise the native window-to-WebView coordinate conversion on a scrolled second page.
    _ = try await web.documentScript(
      "documentTools.zoom(1.5);documentTools.go(2);scrollBy(100,80);return true")
    let cursor = NSPoint(
      x: web.bounds.width * 0.72,
      y: web.bounds.height * (web.isFlipped ? 0.36 : 0.64))
    let windowCursor = web.convert(cursor, to: nil)
    _ = try await web.documentScript(
      """
      const x=innerWidth*.72,y=innerHeight*.36;
      const svg=[...document.querySelectorAll('.page svg')].find(s=>s.getBoundingClientRect().bottom>=y);
      const rect=svg.getBoundingClientRect();
      window.zoomAnchor={svg,u:(x-rect.left)/rect.width,v:(y-rect.top)/rect.height,x,y};return true;
      """)
    for delta in [0.2, -1.0 / 6.0, 0.1, 0.1] {
      try require(a.magnify(delta, at: windowCursor), "cursor pinch accepted")
      let drift =
        try await web.documentScript(
          """
          const a=window.zoomAnchor,r=a.svg.getBoundingClientRect();
          return Math.max(Math.abs(r.left+a.u*r.width-a.x),Math.abs(r.top+a.v*r.height-a.y));
          """) as! Double
      print("Cursor anchor delta=\(delta), drift=\(drift) CSS px")
      try require(drift < 2, "cursor anchor drift: \(drift)")
    }
    _ = try await web.documentScript(
      "delete window.zoomAnchor;documentTools.zoom(1);return documentTools.go(1)")
    print(
      "PASS cursor-anchored pinch: native coordinate conversion, scrolled page 2, zoom in/out, repeated deltas"
    )
    print("PASS arrow events, editing exclusion, search visibility, incremental pinch and limits")
    let text =
      try await web.documentScript("return document.querySelector('svg text').textContent")
      as! String
    let found =
      try await web.documentScript("return documentTools.search(query)", arguments: ["query": text])
      as! [String: Any]
    try require((found["matches"] as? Int ?? 0) > 0, "fixture search")
    _ = try await web.documentScript("documentTools.zoom(2);return documentTools.go(2)")
    let other =
      try await b.renderer!.webView.documentScript("return documentTools.state()") as! [String: Any]
    try require(other["scale"] as? Double == 1, "independent zoom")
    coordinator.open([picture])
    try await wait { coordinator.documents[picture]?.ready == true }
    let imageDocument = coordinator.documents[picture]!
    for (document, name, count) in [(a, "book", 2), (b, "form", 10), (imageDocument, "image", 5)] {
      let exporter = DocumentPDFExporter()
      let data = try await exporter.export(from: document.renderer!.webView, pageCount: count)
      try DocumentPDFExporter.write(
        data, to: evidence.appendingPathComponent(name + ".pdf"), original: document.url)
      let pdf = PDFDocument(data: data)!
      try require(pdf.pageCount == count, "PDF page count")
      if name != "image" { try require((pdf.string?.count ?? 0) > 100, "PDF text") }
      if name != "image" {
        try require(!(pdf.page(at: count - 1)?.string ?? "").isEmpty, "last PDF page text")
      }
      for index in 0..<count {
        let page = pdf.page(at: index)!
        let bounds = page.bounds(for: .mediaBox)
        try require(
          bounds.width > 500 && bounds.width < 700 && bounds.height > 700 && bounds.height < 950,
          "paper dimensions")
        if index == 0 || index == count - 1 {
          let image = page.thumbnail(of: NSSize(width: 700, height: 1000), for: .mediaBox)
          let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
          try rep.representation(using: .png, properties: [:])!.write(
            to: evidence.appendingPathComponent("\(name)-\(index+1).png"))
        }
      }
      try require(
        pdf.printOperation(
          for: NSPrintInfo.shared, scalingMode: .pageScaleDownToFit, autoRotate: true) != nil,
        "print operation")
      print(
        "PASS \(name): \(count) PDF pages, \(pdf.string?.count ?? 0) text characters, print operation"
      )
    }
    let interrupted = DocumentPDFExporter()
    interrupted.progress = { [weak interrupted] _, _ in interrupted?.cancel() }
    do {
      _ = try await interrupted.export(from: web, pageCount: 2)
      throw NSError(domain: "mid export cancellation failed", code: 1)
    } catch is CancellationError {}
    let stateAfterOutput =
      try await web.documentScript("return documentTools.state()") as! [String: Any]
    try require(stateAfterOutput["scale"] as? Double == 2, "export changed viewer zoom")
    let minWindow = a.window!
    minWindow.setContentSize(NSSize(width: 780, height: 450))
    minWindow.contentView!.layoutSubtreeIfNeeded()
    @MainActor func checkControls(_ view: NSView) throws {
      if let control = view as? NSControl, !control.isHidden {
        let rect = control.convert(control.bounds, to: minWindow.contentView!)
        try require(
          rect.minX >= 0 && rect.maxX <= 780 && rect.minY >= 0 && rect.maxY <= 450,
          "viewer control clipped")
      }
      for child in view.subviews where !(child is WKWebView) { try checkControls(child) }
    }
    try checkControls(minWindow.contentView!)
    do {
      try DocumentPDFExporter.write(Data(), to: book, original: book)
      throw NSError(domain: "unsafe write", code: 1)
    } catch DocumentExportError.originalDestination {}
    let cancel = DocumentPDFExporter()
    cancel.cancel()
    do {
      _ = try await cancel.export(from: web, pageCount: 2)
      throw NSError(domain: "cancel failed", code: 1)
    } catch is CancellationError {}
    // Exercise split Korean text and mixed paper geometry through the same live page/exporter.
    _ = try await web.documentScript(
      """
      documentTools.clearSearch();document.querySelector('#pages').innerHTML='<section class="page"><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 800 600"><text x="30" y="50"><tspan>한</tspan><tspan>글 검색</tspan></text></svg></section><section class="page"><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 800"><text x="30" y="50">한글 검색</text></svg></section>';return true;
      """)
    for query in ["한글", "한글".decomposedStringWithCanonicalMapping] {
      let result =
        try await web.documentScript(
          "documentTools.clearSearch();return documentTools.search(query,-1)",
          arguments: ["query": query]) as! [String: Any]
      try require(
        result["matches"] as? Int == 2 && result["selected"] as? Int == 2,
        "split Korean / NFD / reverse search")
    }
    let absent =
      try await web.documentScript(
        "return documentTools.search(query)", arguments: ["query": "' ); window.bad=true; //"])
      as! [String: Any]
    try require(absent["matches"] as? Int == 0, "literal query")
    let mixed = try await DocumentPDFExporter().export(from: web, pageCount: 2)
    let pdf = PDFDocument(data: mixed)!
    try require(
      pdf.page(at: 0)!.bounds(for: .mediaBox).size == NSSize(width: 600, height: 450),
      "landscape dimensions")
    try require(
      pdf.page(at: 1)!.bounds(for: .mediaBox).size == NSSize(width: 450, height: 600),
      "portrait dimensions")
    try mixed.write(to: evidence.appendingPathComponent("mixed.pdf"))
    // Runtime failure and retry use the actual controller without killing unrelated WebKit processes.
    a.renderer!.webViewWebContentProcessDidTerminate(web)
    try require(!a.ready, "runtime failure state")
    a.retryLoad()
    try await wait { a.ready }
    for document in Array(coordinator.documents.values) { document.close() }
    try require(coordinator.documents.isEmpty, "closed registry")
    weak var released: DocumentWindowController?
    do {
      coordinator.open([book])
      released = coordinator.documents[book]
      released?.close()
    }
    try await wait { released == nil }
    coordinator.open([book, form, root.appendingPathComponent(".build/fixtures/image.hwpx")])
    for document in Array(coordinator.documents.values) { document.close() }
    try require(coordinator.documents.isEmpty, "close while queued/loading")
    // The fake service cannot modify the user's Launch Services settings.
    let application = URL(fileURLWithPath: "/Applications/ViewerProbe.app")
    var settings: [String: URL] = [:]
    let service = DefaultApplicationService(
      application: application,
      setter: { url, type, done in
        if type.preferredFilenameExtension == "hwpx" {
          done(NSError(domain: "test cancellation", code: 1))
        } else {
          settings[type.identifier] = url
          done(nil)
        }
      }, reader: { settings[$0.identifier] })
    try require(service.isInstalled, "installed app guard")
    let result: [String: String] = await withCheckedContinuation { continuation in
      service.set(["hwp", "hwpx"]) { continuation.resume(returning: $0) }
    }
    try require(
      result["hwp"] == "지정 완료" && result["hwpx"] != "지정 완료", "partial default association")
    try require(
      !DefaultApplicationService(application: root.appendingPathComponent(".build/Test.app"))
        .isInstalled, "development app guard")
    print(
      "PASS search, zoom isolation, mixed paper, cancellation, original protection, retry, close/release, default app partial failure"
    )
  }
  static func main() {
    NSApplication.shared.setActivationPolicy(.prohibited)
    var done = false
    var passed = false
    Task { @MainActor in
      do {
        try await run()
        passed = true
      } catch { print("FAIL: \(error)") }
      done = true
    }
    while !done { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    exit(passed ? 0 : 1)
  }
}
