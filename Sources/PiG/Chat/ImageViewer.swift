import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Keep the original source, not a rendered thumbnail, for viewing and saving.
enum ImageViewerSource: Sendable {
    case attachment(ImageAttachment)
    case file(String)

    var name: String {
        switch self {
        case .attachment(let attachment): return attachment.name
        case .file(let path): return URL(fileURLWithPath: path).lastPathComponent
        }
    }

    func load() throws -> ImageViewerData {
        let data: Data
        switch self {
        case .attachment(let attachment):
            guard let encoded = attachment.data, let decoded = Data(base64Encoded: encoded) else {
                throw ImageViewerError.unavailable
            }
            data = decoded
        case .file(let path):
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw ImageViewerError.unavailable }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let rotated = (5...8).contains(orientation)
        return ImageViewerData(
            data: data,
            size: CGSize(width: rotated ? height : width, height: rotated ? width : height),
            typeIdentifier: CGImageSourceGetType(source) as String?
        )
    }
}

struct ImageViewerData: Sendable {
    let data: Data
    let size: CGSize
    let typeIdentifier: String?
}

private enum ImageViewerError: LocalizedError {
    case unavailable
    var errorDescription: String? { "The original image is unavailable or could not be decoded." }
}

private struct ImageZoomRequest: Equatable {
    enum Action { case fit, actualSize, zoomIn, zoomOut }
    let id = UUID()
    let action: Action
}

struct ImageViewer: View {
    @Environment(\.appTheme) private var appTheme
    @Environment(\.dismiss) private var dismiss
    let source: ImageViewerSource
    @State private var original: ImageViewerData?
    @State private var image: NSImage?
    @State private var error: String?
    @State private var loading = true
    @State private var saving = false
    @State private var copied = false
    @State private var zoom = ImageZoomRequest(action: .fit)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(source.name)
                    .font(AppFonts.ui(13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 16)
                Group {
                    Button("Fit") { zoom = ImageZoomRequest(action: .fit) }
                        .help("Fit image to window")
                    Button("100%") { zoom = ImageZoomRequest(action: .actualSize) }
                        .help("Actual size — one image pixel per screen pixel")
                    iconButton("Zoom out", symbol: "minus.magnifyingglass") { zoom = ImageZoomRequest(action: .zoomOut) }
                    iconButton("Zoom in", symbol: "plus.magnifyingglass") { zoom = ImageZoomRequest(action: .zoomIn) }
                    iconButton(copied ? "Copied" : "Copy image", symbol: copied ? "checkmark" : "doc.on.doc", action: copy)
                    iconButton("Save image…", symbol: "square.and.arrow.down", action: save)
                        .disabled(saving)
                }
                .disabled(image == nil)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .buttonStyle(GlowButtonStyle(kind: .secondary))
            .padding(12)
            Rectangle().fill(appTheme.line).frame(height: 1)
            Group {
                if let image, let original {
                    ZoomableImageView(image: image, pixelSize: original.size, request: zoom)
                } else if loading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 32))
                        .foregroundStyle(appTheme.muted)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error {
                Text(error)
                    .font(AppFonts.ui(12))
                    .foregroundStyle(appTheme.danger)
                    .textSelection(.enabled)
                    .padding(12)
            } else if let original {
                Text("\(Int(original.size.width)) × \(Int(original.size.height))")
                    .font(AppFonts.ui(11))
                    .foregroundStyle(appTheme.muted)
                    .padding(8)
            }
        }
        .foregroundStyle(appTheme.text)
        .background(appTheme.background)
        .frame(width: 840, height: 600)
        .glowPresentationBackground()
        .task {
            let source = source
            do {
                let loaded = try await Task.detached(priority: .userInitiated) { try source.load() }.value
                try Task.checkCancellation()
                guard let decoded = NSImage(data: loaded.data) else { throw ImageViewerError.unavailable }
                original = loaded
                image = decoded
                loading = false
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                loading = false
            }
        }
    }

    private func iconButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 16) }
            .help(title)
            .accessibilityLabel(title)
    }

    private func copy() {
        guard let image, let original else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([image]) else {
            error = "Could not copy the image."
            return
        }
        if let identifier = original.typeIdentifier {
            pasteboard.setData(original.data, forType: NSPasteboard.PasteboardType(identifier))
        }
        error = nil
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1))
            copied = false
        }
    }

    private func save() {
        guard let original, !saving else { return }
        let panel = NSSavePanel()
        if let identifier = original.typeIdentifier, let type = UTType(identifier) {
            panel.allowedContentTypes = [type]
        }
        panel.nameFieldStringValue = (source.name as NSString).lastPathComponent
        saving = true
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else {
                saving = false
                return
            }
            Task {
                defer { saving = false }
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try original.data.write(to: url, options: .atomic)
                    }.value
                    error = nil
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
        // Present above the viewer's sheet without blocking its accessibility action.
        var parent = NSApp.keyWindow ?? NSApp.mainWindow
        while let sheet = parent?.attachedSheet { parent = sheet }
        if let parent { panel.beginSheetModal(for: parent, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
}

private struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage
    let pixelSize: CGSize
    let request: ImageZoomRequest

    func makeNSView(context: Context) -> ImageScrollView {
        let scroll = ImageScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.001
        scroll.maxMagnification = 32
        let clip = CenteredImageClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        let view = PannableImageView(frame: CGRect(origin: .zero, size: pixelSize))
        view.image = image
        view.imageScaling = .scaleAxesIndependently
        view.setAccessibilityLabel("Full-size image. Use zoom controls or pinch to zoom; drag to pan.")
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: ImageScrollView, context: Context) {
        guard scroll.lastRequest != request.id else { return }
        scroll.lastRequest = request.id
        scroll.fitting = request.action == .fit
        let center = CGPoint(x: scroll.documentVisibleRect.midX, y: scroll.documentVisibleRect.midY)
        switch request.action {
        case .fit: scroll.fitImage()
        case .actualSize:
            scroll.setMagnification(1 / (scroll.window?.backingScaleFactor ?? 1), centeredAt: center)
        case .zoomIn:
            scroll.setMagnification(min(scroll.maxMagnification, scroll.magnification * 1.5), centeredAt: center)
        case .zoomOut:
            scroll.setMagnification(max(scroll.minMagnification, scroll.magnification / 1.5), centeredAt: center)
        }
    }
}

private final class ImageScrollView: NSScrollView {
    var lastRequest: UUID?
    var fitting = true

    override func layout() {
        super.layout()
        if fitting { fitImage() }
    }

    override func magnify(with event: NSEvent) {
        fitting = false
        super.magnify(with: event)
    }

    func fitImage() {
        guard let documentView, contentSize.width > 0, contentSize.height > 0 else { return }
        let size = documentView.frame.size
        let scale = max(minMagnification, min(contentSize.width / size.width, contentSize.height / size.height,
                                              1 / (window?.backingScaleFactor ?? 1)))
        if abs(magnification - scale) > 0.0001 {
            setMagnification(scale, centeredAt: CGPoint(x: size.width / 2, y: size.height / 2))
        }
    }
}

private final class CenteredImageClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        if let documentView {
            if documentView.frame.width < bounds.width {
                bounds.origin.x = (documentView.frame.width - bounds.width) / 2
            }
            if documentView.frame.height < bounds.height {
                bounds.origin.y = (documentView.frame.height - bounds.height) / 2
            }
        }
        return bounds
    }
}

private final class PannableImageView: NSImageView {
    private var dragStart = NSPoint.zero
    private var scrollStart = NSPoint.zero

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
        scrollStart = enclosingScrollView?.contentView.bounds.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let scroll = enclosingScrollView else { return }
        let delta = NSPoint(x: event.locationInWindow.x - dragStart.x, y: event.locationInWindow.y - dragStart.y)
        scroll.contentView.scroll(to: NSPoint(x: scrollStart.x - delta.x / scroll.magnification,
                                             y: scrollStart.y - delta.y / scroll.magnification))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
