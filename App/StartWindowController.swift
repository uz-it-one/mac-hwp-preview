import AppKit

@MainActor final class StartWindowController: NSWindowController {
  private let defaults = DefaultApplicationService()
  private let defaultStatus = NSTextField(wrappingLabelWithString: "")
  private let result = NSTextField(wrappingLabelWithString: "")
  private let open: () -> Void
  private var settingButtons: [NSButton] = []
  init(updates: UpdateController, open: @escaping () -> Void) {
    self.open = open
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
      styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    super.init(window: window)
    window.title = "HWP Preview"
    window.isReleasedWhenClosed = false
    let intro = NSTextField(
      wrappingLabelWithString:
        "HWP · HWPX 문서 뷰어\n\nFinder에서는 문서를 선택하고 스페이스바를 눌러 미리 보세요."
    )
    intro.font = .systemFont(ofSize: 15)
    let openButton = NSButton(title: "문서 열기…", target: self, action: #selector(openDocument))
    let settings = NSButton(
      title: "Quick Look 확장 설정 열기", target: self, action: #selector(openSettings))
    let path = NSTextField(wrappingLabelWithString: Self.settingsPath)
    path.textColor = .secondaryLabelColor
    let defaultRow = NSStackView()
    let defaultButton = NSButton(
      title: "HWP 기본 앱으로 지정", target: self, action: #selector(setDefault))
    settingButtons.append(defaultButton)
    defaultRow.addArrangedSubview(defaultButton)
    let update = NSButton(title: "업데이트 확인…", target: nil, action: nil)
    updates.bind(button: update)
    let updateStatus = NSTextField(wrappingLabelWithString: updates.status)
    updateStatus.textColor = .secondaryLabelColor
    updates.bind(statusLabel: updateStatus)
    let stack = NSStackView(views: [
      intro, openButton, settings, path, defaultStatus, defaultRow, result, update, updateStatus,
    ])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    let content = window.contentView!
    content.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
      stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
    ])
    intro.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    result.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    window.center()
    refreshDefaults()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
  func refreshDefaults() {
    defaultStatus.stringValue =
      "현재 기본 앱 — HWP: \(defaults.current("hwp")) / HWPX: \(defaults.current("hwpx"))"
    if !defaults.isInstalled { result.stringValue = "기본 앱으로 지정하려면 이 앱을 응용 프로그램 폴더에 설치해 주세요." }
    settingButtons.forEach { $0.isEnabled = defaults.isInstalled }
  }
  @objc private func openDocument() { open() }
  @objc private func setDefault() {
    settingButtons.forEach { $0.isEnabled = false }
    result.stringValue = "기본 앱을 변경하는 중…"
    defaults.set(["hwp"]) {
      [weak self] results in
      self?.refreshDefaults()
      self?.result.stringValue = results.keys.sorted().map { "\($0.uppercased()): \(results[$0]!)" }
        .joined(separator: "\n")
    }
  }
  private static var settingsPath: String {
    if #available(macOS 15, *) { return "시스템 설정 → 일반 → 로그인 항목 및 확장 프로그램 → Quick Look" }
    return "시스템 설정 → 개인정보 보호 및 보안 → 확장 프로그램 → Quick Look"
  }
  @objc private func openSettings() {
    let route: String
    if #available(macOS 15, *) {
      route = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
    } else {
      route = "x-apple.systempreferences:com.apple.ExtensionsPreferences"
    }
    if NSWorkspace.shared.open(URL(string: route)!) { return }
    if !NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:")!) {
      result.stringValue = Self.settingsPath
    }
  }
}
