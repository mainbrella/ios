import UIKit
import ImageIO

/// Downsample before decoding so phone photos also fit within an extension's memory budget.
enum InboxAttachment {
    static func image(source: CGImageSource) throws -> UIImage {
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { throw APIError.response(0, "photo") }
        return UIImage(cgImage: thumbnail)
    }

    static func image(data: Data) throws -> UIImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw APIError.response(0, "photo") }
        return try image(source: source)
    }
}

enum FeedbackEncoder {
    static func jpeg(_ image: UIImage) throws -> Data {
        for quality in [0.8, 0.6, 0.4, 0.2] {
            if let data = image.jpegData(compressionQuality: quality), data.count <= 1_048_576 { return data }
        }
        throw APIError.response(413, "file_too_large")
    }
}
