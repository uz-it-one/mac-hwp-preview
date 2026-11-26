import AppKit

@MainActor final class DocumentCoordinator {
  private(set) var documents: [URL: DocumentWindowController] = [:]
  private var queue: [DocumentWindowController] = []
  private var running: Set<ObjectIdentifier> = []
  let assets: URL
  init(assets: URL) { self.assets = assets }
  func open(_ urls: [URL]) {
    for url in urls {
      guard url.isFileURL else { continue }
      let key = url.standardizedFileURL.resolvingSymlinksInPath()
      if let existing = documents[key] ?? documents.values.first(where: { sameFile($0.url, key) }) {
        existing.showWindow(nil)
        existing.window?.makeKeyAndOrderFront(nil)
        continue
      }
      let document = DocumentWindowController(url: key, assets: assets)
      documents[key] = document
      document.openFiles = { [weak self] in self?.open($0) }
      document.onRetry = { [weak self, weak document] in if let document { self?.enqueue(document) }
      }
      document.onClose = { [weak self, weak document] in
        guard let self, let document else { return }
        self.documents.removeValue(forKey: key)
        self.queue.removeAll { $0 === document }
        self.running.remove(ObjectIdentifier(document))
        self.drain()
      }
      document.showWindow(nil)
      enqueue(document)
    }
  }
  private func sameFile(_ first: URL, _ second: URL) -> Bool {
    guard
      let a = try? first.resourceValues(forKeys: [.fileResourceIdentifierKey])
        .fileResourceIdentifier as? NSObject,
      let b = try? second.resourceValues(forKeys: [.fileResourceIdentifierKey])
        .fileResourceIdentifier as? NSObject
    else { return false }
    return a == b
  }
  private func enqueue(_ document: DocumentWindowController) {
    guard !document.isClosed, !queue.contains(where: { $0 === document }),
      !running.contains(ObjectIdentifier(document))
    else { return }
    document.setQueued()
    queue.append(document)
    drain()
  }
  private func drain() {
    while running.count < 2, !queue.isEmpty {
      let document = queue.removeFirst()
      guard !document.isClosed else { continue }
      let id = ObjectIdentifier(document)
      running.insert(id)
      document.load { [weak self] in
        self?.running.remove(id)
        self?.drain()
      }
    }
  }
}
