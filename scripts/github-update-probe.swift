import CryptoKit
import Foundation

@main struct GitHubUpdateProbe {
  static func require(_ condition: @autoclosure () throws -> Bool, _ text: String) throws {
    if try !condition() { throw UpdateFailure(message: "TEST: " + text) }
  }
  static func rejects(_ text: String, _ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw UpdateFailure(message: "TEST accepted: " + text)
  }
  static func fixture(
    _ version: String = "0.2.0", repository: String = GitHubReleaseUpdater.repository,
    prerelease: Bool = false, architecture: String = GitHubReleaseUpdater.architecture,
    digest: String? = nil
  ) -> GitHubRelease {
    let name = "HWP-Preview-\(version)-macOS-\(architecture).zip"
    let base = "https://github.com/\(repository)/releases/download/v\(version)/"
    return GitHubRelease(
      tag_name: "v" + version, draft: false, prerelease: prerelease,
      assets: [
        .init(name: name, size: 3, browser_download_url: URL(string: base + name)!, digest: digest),
        .init(
          name: name + ".sha256", size: 100,
          browser_download_url: URL(string: base + name + ".sha256")!, digest: nil),
      ])
  }
  static func main() async throws {
    let selected = try GitHubReleaseUpdater.select(fixture(), current: "0.1.0")!
    try require(
      try GitHubReleaseUpdater.select(fixture(), current: "0.2.0") == nil, "equal version")
    try require(try GitHubReleaseUpdater.select(fixture(), current: "0.3.0") == nil, "downgrade")
    try require(
      try GitHubReleaseUpdater.select(fixture(prerelease: true), current: "0.1.0") == nil,
      "prerelease")
    try require(
      try GitHubReleaseUpdater.select(fixture(), current: "0.2.0-alpha.1") != nil,
      "stable after alpha")
    try rejects("foreign repository") {
      _ = try GitHubReleaseUpdater.select(fixture(repository: "another/repo"), current: "0.1.0")
    }
    try rejects("unsupported architecture") {
      _ = try GitHubReleaseUpdater.select(fixture(architecture: "no-such-arch"), current: "0.1.0")
    }
    try rejects("empty version") { _ = try ReleaseVersion("") }
    try rejects("invalid version") { _ = try ReleaseVersion("v1.2.no") }
    let data = Data("abc".utf8)
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let checksum = Data("\(hash)  \(selected.archive.name)\n".utf8)
    try GitHubReleaseUpdater.verify(data, checksum: checksum, release: selected)
    try rejects("modified download") {
      try GitHubReleaseUpdater.verify(Data("abd".utf8), checksum: checksum, release: selected)
    }
    try rejects("wrong filename") {
      try GitHubReleaseUpdater.verify(
        data, checksum: Data("\(hash) other.zip".utf8), release: selected)
    }
    try rejects("truncated download") {
      try GitHubReleaseUpdater.verify(Data("ab".utf8), checksum: checksum, release: selected)
    }
    let wrongDigest = try GitHubReleaseUpdater.select(
      fixture(digest: "sha256:" + String(repeating: "0", count: 64)), current: "0.1.0")!
    try rejects("API digest mismatch") {
      try GitHubReleaseUpdater.verify(data, checksum: checksum, release: wrongDigest)
    }
    print("PASS release selection, versions, architecture, checksum and digest rejection")
    if let index = CommandLine.arguments.firstIndex(of: "--archive-tests") {
      let root = URL(fileURLWithPath: CommandLine.arguments[index + 1])
      for name in ["traversal", "absolute", "symlink"] {
        let work = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        try rejects("unsafe ZIP " + name) {
          _ = try GitHubReleaseUpdater.unpack(
            root.appendingPathComponent(name + ".zip"), in: work, version: "0.2.0")
        }
      }
      try require(
        !FileManager.default.fileExists(atPath: root.appendingPathComponent("outside").path),
        "ZIP escaped work folder")
      print("PASS ZIP traversal, absolute path and external symlink rejection")
    }
    if CommandLine.arguments.contains("--live") {
      let updater = GitHubReleaseUpdater()
      guard let release = try await updater.latest(current: "0.0.0") else {
        throw UpdateFailure(message: "No public release")
      }
      let work = FileManager.default.temporaryDirectory.appendingPathComponent(
        "hwp-live-update-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: work) }
      let archive = try await updater.download(release, to: work)
      let app = try GitHubReleaseUpdater.unpack(archive, in: work, version: release.version)
      try require(FileManager.default.fileExists(atPath: app.path), "downloaded app")
      print(
        "PASS live GitHub v\(release.version): ZIP download, SHA-256, extraction, bundle, codesign, architecture; no installation"
      )
    }
  }
}
