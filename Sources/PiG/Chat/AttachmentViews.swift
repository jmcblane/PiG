import SwiftUI
import AppKit
import ImageIO

@MainActor
private final class ImageAttachmentPreviewCache {
    static let shared = ImageAttachmentPreviewCache()
    private let cache = NSCache<NSString, NSImage>()
    private let failed = NSCache<NSString, NSNumber>()

    private init() {
        cache.totalCostLimit = 128 * 1024 * 1024
        cache.countLimit = 160
        failed.countLimit = 512
    }

    func cachedImage(for attachment: ImageAttachment, maxDimension: Int) -> NSImage? {
        let key = cacheKey(for: attachment, maxDimension: maxDimension)
        if let cached = cache.object(forKey: key) { return cached }
        return nil
    }

    func prepareImage(for attachment: ImageAttachment, maxDimension: Int) async -> NSImage? {
        let key = cacheKey(for: attachment, maxDimension: maxDimension)
        if let cached = cache.object(forKey: key) { return cached }
        if failed.object(forKey: key) != nil { return nil }
        guard ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(attachment.mimeType),
              let encoded = attachment.data else {
            failed.setObject(true, forKey: key)
            return nil
        }

        let thumbnail = await Task.detached(priority: .userInitiated) {
            Self.thumbnail(encoded: encoded, maxDimension: maxDimension)
        }.value
        guard !Task.isCancelled else { return nil }
        guard let thumbnail else {
            failed.setObject(true, forKey: key)
            return nil
        }

        let prepared = NSImage(
            cgImage: thumbnail,
            size: NSSize(width: CGFloat(thumbnail.width), height: CGFloat(thumbnail.height))
        )
        cache.setObject(prepared, forKey: key, cost: thumbnail.width * thumbnail.height * 4)
        return prepared
    }

    func failedImage(for attachment: ImageAttachment, maxDimension: Int) -> Bool {
        failed.object(forKey: cacheKey(for: attachment, maxDimension: maxDimension)) != nil
    }

    private func cacheKey(for attachment: ImageAttachment, maxDimension: Int) -> NSString {
        "\(attachment.id)-\(maxDimension)" as NSString
    }

    nonisolated private static func thumbnail(encoded: String, maxDimension: Int) -> CGImage? {
        guard let data = Data(base64Encoded: encoded),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

struct ImageAttachmentThumbnail: View {
    enum Style: Equatable {
        case message
        case composer
    }

    @Environment(\.appTheme) private var appTheme
    let attachment: ImageAttachment
    let maxDimension: Int
    let style: Style
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                preview(image)
            } else if style == .message && failed {
                Label("Image unavailable", systemImage: "photo")
                    .font(AppFonts.ui(12))
                    .foregroundStyle(appTheme.muted)
            } else {
                placeholder
            }
        }
        .task(id: "\(attachment.id)-\(maxDimension)") {
            image = nil
            failed = false
            image = ImageAttachmentPreviewCache.shared.cachedImage(
                for: attachment,
                maxDimension: maxDimension
            )
            guard image == nil else {
                failed = false
                return
            }

            let prepared = await ImageAttachmentPreviewCache.shared.prepareImage(
                for: attachment,
                maxDimension: maxDimension
            )
            guard !Task.isCancelled else { return }
            image = prepared
            failed = prepared == nil && ImageAttachmentPreviewCache.shared.failedImage(
                for: attachment,
                maxDimension: maxDimension
            )
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        switch style {
        case .message:
            Image(systemName: "photo")
                .foregroundStyle(appTheme.muted)
        case .composer:
            Image(systemName: "photo")
                .frame(width: 42, height: 42)
                .foregroundStyle(appTheme.muted)
        }
    }

    @ViewBuilder
    private func preview(_ image: NSImage) -> some View {
        switch style {
        case .message:
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 360, maxHeight: 320, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .help(attachment.name)
        case .composer:
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

struct MessageImagesView: View {
    @Environment(\.appTheme) private var appTheme
    let images: [ImageAttachment]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 360), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(images) { attachment in
                ImageAttachmentThumbnail(attachment: attachment, maxDimension: 1024, style: .message)
            }
        }
    }
}

struct ImagePreviewView: View {
    @Environment(\.appTheme) private var appTheme
    let path: String

    var body: some View {
        if let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 760, maxHeight: 520, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contextMenu {
                    Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(path, forType: .string)
                    }
                }
                .help(path)
        }
    }
}
