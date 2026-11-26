import AppKit

@main struct AppViewerProbe {
  @MainActor static func require(_ condition: Bool, _ message: String) throws {
    if !condition {
      throw NSError(
        domain: "AppViewerProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
  }
  @MainActor static func wait(_ condition: () -> Bool) async throws {
    let end = Date().addingTimeInterval(40)
    while !condition() {
      if Date() > end { throw NSError(domain: "timeout", code: 1) }
      try await Task.sleep(nanoseconds: 30_000_000)
    }
  }
  static func main() {
    MainActor.assumeIsolated {
      let app = NSApplication.shared
      app.setActivationPolicy(.prohibited)
      let delegate = AppDelegate()
      app.delegate = delegate
      let root = URL(fileURLWithPath: CommandLine.arguments[1])
      let cold = CommandLine.arguments[2] == "cold"
      let book = root.appendingPathComponent(".build/fixtures/book.hwp")
      if cold { delegate.application(app, open: [book]) }
      Task { @MainActor in
        do {
          try await Task.sleep(nanoseconds: 300_000_000)
          if cold {
            try await wait { delegate.documents.documents[book]?.ready == true }
            try require(
              !app.windows.contains { $0.isVisible && $0.title == "HWP Preview" },
              "cold open showed settings")
          } else {
            try await wait { app.windows.contains { $0.isVisible && $0.title == "HWP Preview" } }
            let window = app.windows.first { $0.title == "HWP Preview" }!
            let content = window.contentView!
            content.layoutSubtreeIfNeeded()
            @MainActor func check(_ view: NSView) throws {
              if let control = view as? NSControl, !control.isHidden {
                let rect = control.convert(control.bounds, to: content)
                try require(
                  rect.minY >= 0 && rect.maxY <= content.bounds.height,
                  "start control clipped: \(control)")
              }
              for child in view.subviews { try check(child) }
            }
            try check(content)
            if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
              content.cacheDisplay(in: content.bounds, to: bitmap)
              try bitmap.representation(using: .png, properties: [:])!.write(
                to: root.appendingPathComponent(".build/viewer-evidence/start-controls.png"))
            }
            delegate.application(app, open: [book])
            try await wait { delegate.documents.documents[book]?.ready == true }
          }
          delegate.application(app, open: [book])
          try require(delegate.documents.documents.count == 1, "warm duplicate")
          try require(app.mainMenu?.items.count == 5, "native menu setup")
          delegate.showStart()
          delegate.showStart()
          try require(
            app.windows.filter { $0.isVisible && $0.title == "HWP Preview" }.count == 1,
            "settings singleton")
          print(
            "PASS app \(cold ? "cold" : "start"): launch routing, settings layout, warm open, menus"
          )
          exit(0)
        } catch {
          print("FAIL app: \(error)")
          exit(1)
        }
      }
      app.run()
    }
  }
}
