import AppKit
import UniformTypeIdentifiers

@MainActor final class DefaultApplicationService {
  typealias Setter = (URL, UTType, @escaping @Sendable (Error?) -> Void) -> Void
  private let application: URL
  private let setter: Setter
  private let reader: (UTType) -> URL?
  init(
    application: URL = Bundle.main.bundleURL,
    setter: @escaping Setter = {
      NSWorkspace.shared.setDefaultApplication(at: $0, toOpen: $1, completion: $2)
    },
    reader: @escaping (UTType) -> URL? = { NSWorkspace.shared.urlForApplication(toOpen: $0) }
  ) {
    self.application = application
    self.setter = setter
    self.reader = reader
  }
  var isInstalled: Bool {
    let path = application.standardizedFileURL.resolvingSymlinksInPath().path
    let user =
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
      + "/"
    return application.pathExtension == "app"
      && (path.hasPrefix("/Applications/") || path.hasPrefix(user))
  }
  func type(for suffix: String) -> UTType? {
    guard ["hwp", "hwpx"].contains(suffix), let type = UTType(filenameExtension: suffix),
      type != .data, type != .content, type.preferredFilenameExtension?.lowercased() == suffix
    else { return nil }
    return type
  }
  func current(_ suffix: String) -> String {
    guard let type = type(for: suffix), let url = reader(type) else { return "지정되지 않음" }
    return url.deletingPathExtension().lastPathComponent
  }
  func set(_ suffixes: [String], completion: @escaping ([String: String]) -> Void) {
    guard isInstalled else {
      completion(Dictionary(uniqueKeysWithValues: suffixes.map { ($0, "앱을 응용 프로그램 폴더에 설치해 주세요.") }))
      return
    }
    var results: [String: String] = [:]
    func next(_ index: Int) {
      guard index < suffixes.count else {
        completion(results)
        return
      }
      let suffix = suffixes[index]
      guard let type = type(for: suffix) else {
        results[suffix] = "지원 파일 형식을 확인하지 못했습니다."
        next(index + 1)
        return
      }
      setter(application, type) { [self] error in
        DispatchQueue.main.async {
          if let error {
            results[suffix] = error.localizedDescription
          } else if self.reader(type)?.standardizedFileURL.resolvingSymlinksInPath()
            == self.application.standardizedFileURL.resolvingSymlinksInPath()
          {
            results[suffix] = "지정 완료"
          } else {
            results[suffix] = "변경을 확인하지 못했습니다. Finder의 정보 가져오기에서 확인해 주세요."
          }
          next(index + 1)
        }
      }
    }
    next(0)
  }
}
