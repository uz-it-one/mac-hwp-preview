import CryptoKit
import Darwin
import Foundation

struct UpdateFailure: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

struct ReleaseVersion: Comparable {
  let parts: [Int]
  let prerelease: Bool
  init(_ raw: String) throws {
    let text = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
    let components = text.split(separator: "-", maxSplits: 1)
    guard !components.isEmpty else { throw UpdateFailure(message: "버전이 비어 있습니다.") }
    let numbers = components[0].split(separator: ".", omittingEmptySubsequences: false)
    guard numbers.count == 3, numbers.allSatisfy({ Int($0) != nil && Int($0)! >= 0 }) else {
      throw UpdateFailure(message: "업데이트 버전 형식을 확인하지 못했습니다.")
    }
    parts = numbers.map { Int($0)! }
    prerelease = components.count > 1
  }
  static func < (a: Self, b: Self) -> Bool {
    if a.parts != b.parts { return a.parts.lexicographicallyPrecedes(b.parts) }
    return a.prerelease && !b.prerelease
  }
}

struct GitHubRelease: Decodable {
  struct Asset: Decodable {
    let name: String
    let size: Int
    let browser_download_url: URL
    let digest: String?
  }
  let tag_name: String
  let draft: Bool
  let prerelease: Bool
  let assets: [Asset]
}

struct ReleaseDownload {
  let version: String
  let archive: GitHubRelease.Asset
  let checksum: GitHubRelease.Asset
}

/// HTTPS GitHub release assets are the update trust source; SHA-256 verifies download integrity.
struct GitHubReleaseUpdater {
  static let repository = "uz-it-one/mac-hwp-preview"
  static let latestURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
  static let releasesURL = URL(string: "https://github.com/\(repository)/releases")!
  #if arch(arm64)
    static let architecture = "arm64"
  #else
    static let architecture = "x86_64"
  #endif

  static func select(_ release: GitHubRelease, current: String, architecture: String = architecture)
    throws -> ReleaseDownload?
  {
    guard !release.draft, !release.prerelease else { return nil }
    let version = try ReleaseVersion(release.tag_name)
    guard !version.prerelease, version > (try ReleaseVersion(current)) else { return nil }
    let number = version.parts.map(String.init).joined(separator: ".")
    guard release.tag_name == "v" + number else {
      throw UpdateFailure(message: "릴리스 태그 형식이 올바르지 않습니다.")
    }
    let name = "HWP-Preview-\(number)-macOS-\(architecture).zip"
    let archives = release.assets.filter { $0.name == name }
    let hashes = release.assets.filter { $0.name == name + ".sha256" }
    guard archives.count == 1, hashes.count == 1,
      archives[0].size > 0, archives[0].size <= 512 * 1024 * 1024,
      hashes[0].size > 0, hashes[0].size <= 4096
    else {
      throw UpdateFailure(message: "이 Mac용 ZIP 또는 SHA-256 파일이 릴리스에 없습니다.")
    }
    for asset in [archives[0], hashes[0]] {
      let expected =
        "https://github.com/\(repository)/releases/download/\(release.tag_name)/\(asset.name)"
      guard asset.browser_download_url.absoluteString == expected else {
        throw UpdateFailure(message: "업데이트 파일 주소가 지정된 저장소와 일치하지 않습니다.")
      }
    }
    return ReleaseDownload(version: number, archive: archives[0], checksum: hashes[0])
  }

  func latest(current: String) async throws -> ReleaseDownload? {
    var request = URLRequest(url: Self.latestURL)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    let data = try await fetch(request, maximum: 2 * 1024 * 1024)
    return try Self.select(JSONDecoder().decode(GitHubRelease.self, from: data), current: current)
  }

  private func fetch(_ input: URLRequest, maximum: Int) async throws -> Data {
    var request = input
    request.timeoutInterval = 60
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("HWP-Preview-Updater", forHTTPHeaderField: "User-Agent")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForResource = 180
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200,
      response.url?.scheme == "https",
      [
        "api.github.com", "github.com", "release-assets.githubusercontent.com",
        "objects.githubusercontent.com",
      ].contains(response.url?.host ?? "")
    else {
      throw UpdateFailure(message: "업데이트 서버에 연결하지 못했습니다. 잠시 후 다시 확인해 주세요.")
    }
    guard response.expectedContentLength <= maximum else {
      throw UpdateFailure(message: "업데이트 파일 크기 한도를 초과했습니다.")
    }
    var data = Data()
    for try await byte in bytes {
      if data.count >= maximum { throw UpdateFailure(message: "업데이트 파일 크기 한도를 초과했습니다.") }
      data.append(byte)
    }
    return data
  }

  static func verify(_ data: Data, checksum: Data, release: ReleaseDownload) throws {
    guard data.count == release.archive.size,
      let line = String(data: checksum, encoding: .utf8)
    else {
      throw UpdateFailure(message: "업데이트 파일이 완전히 다운로드되지 않았습니다.")
    }
    let fields = line.split(whereSeparator: { $0.isWhitespace })
    guard fields.count == 2, fields[1] == release.archive.name,
      fields[0].count == 64, fields[0].allSatisfy({ $0.isHexDigit })
    else {
      throw UpdateFailure(message: "SHA-256 검증 파일 형식이 올바르지 않습니다.")
    }
    let expected = fields[0].lowercased()
    let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard actual == expected else { throw UpdateFailure(message: "SHA-256이 일치하지 않아 업데이트를 중단했습니다.") }
    if let digest = release.archive.digest, digest != "sha256:" + actual {
      throw UpdateFailure(message: "SHA-256이 일치하지 않습니다.")
    }
  }

  func download(_ release: ReleaseDownload, to folder: URL) async throws -> URL {
    let checksum = try await fetch(
      URLRequest(url: release.checksum.browser_download_url), maximum: 4096)
    let data = try await fetch(
      URLRequest(url: release.archive.browser_download_url), maximum: release.archive.size)
    try Self.verify(data, checksum: checksum, release: release)
    let archive = folder.appendingPathComponent("update.zip")
    try data.write(to: archive, options: .atomic)
    return archive
  }

  static func command(_ executable: String, _ arguments: [String]) throws -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = arguments
    let output = Pipe()
    task.standardOutput = output
    task.standardError = FileHandle.nullDevice
    try task.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else {
      throw UpdateFailure(message: "업데이트 앱 검증 또는 압축 해제에 실패했습니다.")
    }
    return String(decoding: data, as: UTF8.self)
  }

  static func unpack(_ archive: URL, in folder: URL, version: String) throws -> URL {
    let listing = try command("/usr/bin/tar", ["-tf", archive.path])
    let paths = listing.split(separator: "\n")
    guard !paths.isEmpty, paths.count < 30000,
      paths.allSatisfy({ item in
        let parts = item.split(separator: "/")
        return !item.hasPrefix("/") && !parts.contains("..") && !item.contains("\\")
          && (parts.first == "HWP Preview.app" || parts.first == "__MACOSX")
      })
    else { throw UpdateFailure(message: "업데이트 ZIP의 경로가 올바르지 않습니다.") }
    let extracted = folder.appendingPathComponent("extracted", isDirectory: true)
    try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false)
    // bsdtar's default extraction refuses traversal and paths through pre-existing symlinks.
    _ = try command(
      "/usr/bin/tar",
      ["-xf", archive.path, "-C", extracted.path, "--no-same-owner", "--no-same-permissions"])
    let app = extracted.appendingPathComponent("HWP Preview.app", isDirectory: true)
    try validate(app, version: version)
    return app
  }

  static func validate(_ app: URL, version: String) throws {
    // realpath keeps /var and /private/var aliases consistent, including dangling framework links.
    func physicalPath(_ url: URL) throws -> String {
      var ancestor = url.standardizedFileURL
      var suffix: [String] = []
      while true {
        if let resolved = realpath(ancestor.path, nil) {
          defer { free(resolved) }
          return suffix.reduce(URL(fileURLWithPath: String(cString: resolved))) {
            $0.appendingPathComponent($1)
          }.path
        }
        guard ancestor.path != "/" else { throw UpdateFailure(message: "업데이트 경로를 확인하지 못했습니다.") }
        suffix.insert(ancestor.lastPathComponent, at: 0)
        ancestor.deleteLastPathComponent()
      }
    }
    guard (try app.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
      throw UpdateFailure(message: "업데이트 앱 경로가 올바르지 않습니다.")
    }
    let root = try physicalPath(app)
    guard
      let files = FileManager.default.enumerator(
        at: app, includingPropertiesForKeys: [.isSymbolicLinkKey])
    else {
      throw UpdateFailure(message: "업데이트 앱을 찾을 수 없습니다.")
    }
    for case let url as URL in files {
      var target = url
      if let link = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
        target =
          URL(fileURLWithPath: link, relativeTo: url.deletingLastPathComponent()).absoluteURL
          .standardizedFileURL
      }
      let resolved = try physicalPath(target)
      guard resolved.hasPrefix(root + "/") else {
        throw UpdateFailure(message: "업데이트 앱에 외부 경로 참조가 있습니다.")
      }
    }
    let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
    guard
      let info = try PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      info["CFBundleIdentifier"] as? String == "org.hwp-preview.app",
      info["CFBundleShortVersionString"] as? String == version,
      info["HWPPreviewVersion"] as? String == version,
      info["CFBundleExecutable"] as? String == "HWPPreview"
    else {
      throw UpdateFailure(message: "업데이트 앱의 식별자 또는 버전이 일치하지 않습니다.")
    }
    if let minimum = info["LSMinimumSystemVersion"] as? String {
      let system = ProcessInfo.processInfo.operatingSystemVersion
      let running = "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
      if minimum.compare(running, options: .numeric) == .orderedDescending {
        throw UpdateFailure(message: "이 업데이트에는 macOS \(minimum) 이상이 필요합니다.")
      }
    }
    _ = try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    _ = try command(
      "/usr/bin/lipo",
      ["-verify_arch", architecture, app.appendingPathComponent("Contents/MacOS/HWPPreview").path])
  }
}
