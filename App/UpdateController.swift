import AppKit

@MainActor final class UpdateController: NSObject {
  private var started = false
  private var busy = false { didSet { button?.isEnabled = canCheck } }
  private weak var button: NSButton?
  private weak var statusLabel: NSTextField?
  private(set) var status = "GitHub Releases에서 앱 실행 시 업데이트를 확인합니다." {
    didSet { statusLabel?.stringValue = status }
  }
  var canCheck: Bool { !busy }
  private let updater = GitHubReleaseUpdater()
  private var currentVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "HWPPreviewVersion") as? String ?? "0.0.0"
  }
  private var resultFile: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("HWP Preview/update-result.txt")
  }
  func bind(button: NSButton) {
    self.button = button
    button.target = self
    button.action = #selector(check)
    button.isEnabled = canCheck
  }
  func bind(statusLabel: NSTextField) {
    self.statusLabel = statusLabel
    statusLabel.stringValue = status
  }
  func start() {
    guard !started else { return }
    started = true
    // Isolated app tests do not make production network requests.
    guard Bundle.main.bundleIdentifier == "org.hwp-preview.app" else { return }
    if let result = try? String(contentsOf: resultFile, encoding: .utf8) {
      try? FileManager.default.removeItem(at: resultFile)
      if result.trimmingCharacters(in: .whitespacesAndNewlines) == "failed" {
        status = "업데이트 설치에 실패하여 이전 앱으로 복구했습니다. 다시 시도해 주세요."
        message("업데이트 설치 실패", status)
        return
      }
    }
    performCheck(manual: false)
  }
  @objc func check() { performCheck(manual: true) }
  private func message(_ title: String, _ text: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = text
    alert.addButton(withTitle: "확인")
    alert.runModal()
  }
  private func performCheck(manual: Bool) {
    guard !busy else { return }
    busy = true
    status = "업데이트를 확인하는 중…"
    Task {
      defer { busy = false }
      var requestedInstall = false
      do {
        guard let release = try await updater.latest(current: currentVersion) else {
          status = "현재 버전(\(currentVersion))이 최신입니다."
          if manual { message("업데이트 확인", status) }
          return
        }
        status = "새 버전 \(release.version)을 설치할 수 있습니다."
        let alert = NSAlert()
        alert.messageText = "HWP Preview \(release.version) 업데이트"
        alert.addButton(withTitle: "업데이트 및 재시작")
        alert.addButton(withTitle: "나중에")
        alert.addButton(withTitle: "릴리스 보기")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
          requestedInstall = true
          try await install(release)
        case .alertThirdButtonReturn: NSWorkspace.shared.open(GitHubReleaseUpdater.releasesURL)
        default: break
        }
      } catch {
        status = error.localizedDescription
        if manual || requestedInstall { message("업데이트하지 못했습니다", status) }
      }
    }
  }
  private func install(_ release: ReleaseDownload) async throws {
    let fm = FileManager.default
    let target = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
    let parent = target.deletingLastPathComponent()
    let userApplications = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
      .path
    guard parent.path == "/Applications" || parent.path == userApplications,
      fm.isWritableFile(atPath: parent.path), fm.isWritableFile(atPath: target.path)
    else {
      throw UpdateFailure(message: "앱을 응용 프로그램 폴더에 설치한 뒤 업데이트해 주세요.")
    }
    let token = UUID().uuidString
    let work = fm.temporaryDirectory.appendingPathComponent(
      "hwp-update-" + token, isDirectory: true)
    let staged = parent.appendingPathComponent(
      ".HWPPreview-update-" + token + ".app", isDirectory: true)
    let backup = parent.appendingPathComponent(
      ".HWPPreview-backup-" + token + ".app", isDirectory: true)
    try fm.createDirectory(
      at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    var handedOff = false
    defer {
      if !handedOff {
        try? fm.removeItem(at: work)
        try? fm.removeItem(at: staged)
      }
    }
    status = "업데이트 ZIP 다운로드 중…"
    let archive = try await updater.download(release, to: work)
    status = "업데이트 앱 검증 중…"
    let candidate = try await Task.detached(priority: .userInitiated) {
      try GitHubReleaseUpdater.unpack(archive, in: work, version: release.version)
    }.value
    try fm.copyItem(at: candidate, to: staged)
    try await Task.detached(priority: .userInitiated) {
      try GitHubReleaseUpdater.validate(staged, version: release.version)
    }.value
    let helper = work.appendingPathComponent("install-update.sh")
    guard
      let resource = Bundle.main.resourceURL?.appendingPathComponent("Updater/install-update.sh")
    else {
      throw UpdateFailure(message: "업데이트 설치 도구를 찾을 수 없습니다.")
    }
    try fm.copyItem(at: resource, to: helper)
    try fm.createDirectory(
      at: resultFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    task.arguments = [
      helper.path, String(ProcessInfo.processInfo.processIdentifier), staged.path,
      target.path, backup.path, resultFile.path, work.path, "/usr/bin/open",
    ]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    try task.run()
    handedOff = true
    NSApp.terminate(nil)
  }
}
