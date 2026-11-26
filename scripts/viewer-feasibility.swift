import AppKit
import PDFKit
import WebKit

@main struct Probe {
  static func main() {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let assets = URL(fileURLWithPath: CommandLine.arguments[1])
    let renderer = WebRenderer(assets: assets)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 900), styleMask: .titled,
      backing: .buffered, defer: false)
    window.contentView = renderer.webView
    window.orderBack(nil)
    var done = false
    var ok = false
    renderer.render(URL(fileURLWithPath: CommandLine.arguments[2])) { result in
      guard case .success = result else {
        done = true
        return
      }
      renderer.webView.callAsyncJavaScript(
        "const s=document.querySelector('.page svg');return {rect:{x:s.getBoundingClientRect().x+scrollX,y:s.getBoundingClientRect().y+scrollY,width:s.getBoundingClientRect().width,height:s.getBoundingClientRect().height},text:s.querySelector('text')?.textContent||''};",
        arguments: [:], in: nil, in: .page
      ) { result in
        guard case .success(let raw) = result, let v = raw as? [String: Any],
          let r = v["rect"] as? [String: Double]
        else {
          done = true
          return
        }
        let c = WKPDFConfiguration()
        c.rect = CGRect(x: r["x"]!, y: r["y"]!, width: r["width"]!, height: r["height"]!)
        renderer.webView.createPDF(configuration: c) { result in
          guard case .success(let data) = result, let pdf = PDFDocument(data: data) else {
            done = true
            return
          }
          print(
            "PDF pages=\(pdf.pageCount) text=\(pdf.string?.count ?? 0) bounds=\(pdf.page(at:0)!.bounds(for:.mediaBox))"
          )
          try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
          renderer.webView.find(v["text"] as? String ?? "", configuration: WKFindConfiguration()) {
            result in
            print("nativeFind=\(result.matchFound)")
            ok = pdf.pageCount == 1 && (pdf.string?.count ?? 0) > 0
            done = true
          }
        }
      }
    }
    let end = Date().addingTimeInterval(40)
    while !done && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    renderer.dispose()
    exit(ok ? 0 : 1)
  }
}
