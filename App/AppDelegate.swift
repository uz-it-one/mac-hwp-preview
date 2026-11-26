import AppKit
import UniformTypeIdentifiers

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
  private var startWindow: StartWindowController?
  private let updates = UpdateController()
  private(set) lazy var documents = DocumentCoordinator(
    assets: Bundle.main.resourceURL!.appendingPathComponent("Web"))
  private var launched = false
  private var pending: [URL] = []
  func applicationDidFinishLaunching(_ notification: Notification) {
    buildMenus()
    updates.start()
    launched = true
    documents.open(pending)
    pending.removeAll()
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if self.documents.documents.isEmpty { self.showStart() }
    }
  }
  func application(_ application: NSApplication, open urls: [URL]) {
    if launched { documents.open(urls) } else { pending += urls }
    NSApp.activate(ignoringOtherApps: true)
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if !flag { showStart() }
    return true
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  @objc func showStart() {
    if startWindow == nil {
      startWindow = StartWindowController(
        updates: updates, open: { [weak self] in self?.openDocument() })
    }
    startWindow?.refreshDefaults()
    startWindow?.showWindow(nil)
    startWindow?.window?.makeKeyAndOrderFront(nil)
  }
  @objc func openDocument() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.allowedContentTypes = ["hwp", "hwpx"].compactMap { UTType(filenameExtension: $0) }
    panel.begin { [weak self] response in if response == .OK { self?.documents.open(panel.urls) } }
  }
  private var activeDocument: DocumentWindowController? {
    NSApp.mainWindow?.windowController as? DocumentWindowController
  }
  @objc func documentAction(_ sender: NSMenuItem) {
    guard let document = activeDocument, let name = sender.representedObject as? String else {
      return
    }
    document.perform(NSSelectorFromString(name))
  }
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    if item.action == #selector(documentAction(_:)) { return activeDocument?.ready == true }
    if item.action == #selector(checkUpdates) { return updates.canCheck }
    return true
  }
  @objc func checkUpdates() { updates.check() }
  private func buildMenus() {
    let main = NSMenu()
    NSApp.mainMenu = main
    func menu(_ title: String) -> NSMenu {
      let item = NSMenuItem()
      let result = NSMenu(title: title)
      item.submenu = result
      main.addItem(item)
      return result
    }
    func add(
      _ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "",
      target: AnyObject? = nil, modifiers: NSEvent.ModifierFlags = .command
    ) {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
      item.target = target
      item.keyEquivalentModifierMask = modifiers
      menu.addItem(item)
    }
    func document(
      _ menu: NSMenu, _ title: String, _ action: String, _ key: String,
      _ modifiers: NSEvent.ModifierFlags = .command
    ) {
      let item = NSMenuItem(title: title, action: #selector(documentAction(_:)), keyEquivalent: key)
      item.target = self
      item.representedObject = action
      item.keyEquivalentModifierMask = modifiers
      menu.addItem(item)
    }
    let app = menu("HWP Preview")
    add(app, "시작 및 설정…", #selector(showStart), ",", target: self)
    add(app, "업데이트 확인…", #selector(checkUpdates), target: self)
    app.addItem(.separator())
    add(app, "HWP Preview 종료", #selector(NSApplication.terminate(_:)), "q")
    let file = menu("파일")
    add(file, "열기…", #selector(openDocument), "o", target: self)
    add(file, "닫기", #selector(NSWindow.performClose(_:)), "w")
    document(file, "PDF 저장…", "savePDF", "s", [.command, .shift])
    document(file, "인쇄…", "printDocument", "p")
    let edit = menu("편집")
    add(edit, "복사", #selector(NSText.copy(_:)), "c")
    add(edit, "붙여넣기", #selector(NSText.paste(_:)), "v")
    add(edit, "전체 선택", #selector(NSText.selectAll(_:)), "a")
    document(edit, "찾기…", "focusSearch", "f")
    document(edit, "다음 찾기", "findNext", "g")
    document(edit, "이전 찾기", "findPrevious", "g", [.command, .shift])
    let view = menu("보기")
    document(view, "확대", "zoomIn", "+")
    document(view, "축소", "zoomOut", "-")
    document(view, "너비 맞춤", "fitWidth", "0")
    let windows = menu("윈도우")
    NSApp.windowsMenu = windows
    add(windows, "최소화", #selector(NSWindow.performMiniaturize(_:)), "m")
    add(windows, "모두 앞으로 가져오기", #selector(NSApplication.arrangeInFront(_:)))
  }
}
