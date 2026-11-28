import AppKit
import QuickLookThumbnailing
import WebKit
import os

@objc(ThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {
    private var active: [UUID: WebRenderer] = [:]
    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        DispatchQueue.main.async {
            guard let assets = Bundle(for: Self.self).resourceURL?.appendingPathComponent("Web") else {
                handler(nil, PreviewFailure.engineMissing); return
            }
            let id = UUID()
            let renderer = WebRenderer(assets: assets)
            self.active[id] = renderer
            let release = { renderer.dispose(); self.active[id] = nil }
            renderer.render(request.fileURL, thumbnail: true) { result in
                switch result {
                case .failure(let error):
                    Logger(subsystem:"org.hwp-preview",category:"thumbnail").error("WASM render failed")
                    release(); handler(nil,error)
                case .success(let info):
                    let width = info["width"] as? Double ?? 794
                    let height = info["height"] as? Double ?? 1123
                    guard width.isFinite, height.isFinite, width > 0, height > 0, width < 20000, height < 20000 else {
                        release(); handler(nil,PreviewFailure.invalid); return
                    }
                    let scale = min(request.maximumSize.width / width, request.maximumSize.height / height)
                    let size = NSSize(width:width * scale,height:height * scale)
                    renderer.webView.setFrameSize(size)
                    renderer.webView.takeSnapshot(with:nil) { image,error in
                        defer { release() }
                        guard let image else { handler(nil,error ?? PreviewFailure.engineFailed); return }
                        Logger(subsystem:"org.hwp-preview",category:"thumbnail").notice("WASM thumbnail complete")
                        handler(QLThumbnailReply(contextSize:size,currentContextDrawing:{
                            image.draw(in:NSRect(origin:.zero,size:size)); return true
                        }),nil)
                    }
                }
            }
        }
    }
}
