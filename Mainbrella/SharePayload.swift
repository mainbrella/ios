import UIKit
import UniformTypeIdentifiers
import ImageIO

enum ShareFailure: LocalizedError {
    case unsupported, tooManyImages, empty, tooLarge, accountChanged
    var errorDescription: String? {
        switch self {
        case .unsupported: return "Share a web link, text, or one photo. Files and videos aren't supported yet."
        case .tooManyImages: return "Share one photo at a time."
        case .empty: return "The shared item couldn't be read. Close this sheet and share it again."
        case .tooLarge: return "This text is too long. Share a shorter selection."
        case .accountChanged: return "Your account changed. Close this sheet and share again."
        }
    }
}

struct SharePayload {
    let text: String
    let image: UIImage?
    let attachment: Data?

    static func load(_ providers: [NSItemProvider]) async throws -> SharePayload {
        guard !providers.isEmpty, providers.count <= 8 else { throw ShareFailure.unsupported }
        var parts: [String] = []
        var image: UIImage?
        var attachment: Data?
        for provider in providers {
            try Task.checkCancellation()
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                guard image == nil else { throw ShareFailure.tooManyImages }
                let prepared = try await loadImage(provider)
                image = prepared.0; attachment = prepared.1
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                let url: URL = try await withCheckedThrowingContinuation { continuation in
                    if provider.canLoadObject(ofClass: NSURL.self) {
                        provider.loadObject(ofClass: NSURL.self) { value, error in
                            if let error { continuation.resume(throwing: error) }
                            else if let url = value as? URL { continuation.resume(returning: url) }
                            else { continuation.resume(throwing: ShareFailure.empty) }
                        }
                        return
                    }
                    provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { value, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let url = value as? URL { continuation.resume(returning: url) }
                        else if let text = value as? String, let url = URL(string: text) { continuation.resume(returning: url) }
                        else if let data = value as? Data, let text = String(data: data, encoding: .utf8), let url = URL(string: text) { continuation.resume(returning: url) }
                        else { continuation.resume(throwing: ShareFailure.empty) }
                    }
                }
                guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { throw ShareFailure.unsupported }
                if !parts.contains(url.absoluteString) { parts.append(url.absoluteString) }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
                let type = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .text) == true } ?? UTType.text.identifier
                let value: String = try await withCheckedThrowingContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: type, options: nil) { value, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let text = value as? String { continuation.resume(returning: text) }
                        else if let data = value as? Data, let text = String(data: data, encoding: .utf8) { continuation.resume(returning: text) }
                        else { continuation.resume(throwing: ShareFailure.empty) }
                    }
                }
                if !value.isEmpty, !parts.contains(value) { parts.append(value) }
            } else {
                // Never silently drop an attachment from a mixed share.
                throw ShareFailure.unsupported
            }
            guard parts.reduce(0, { $0 + $1.utf8.count }) <= 262_144 else { throw ShareFailure.tooLarge }
        }
        try Task.checkCancellation()
        let text = parts.joined(separator: "\n\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || image != nil else { throw ShareFailure.empty }
        return SharePayload(text: text, image: image, attachment: attachment)
    }

    private static func loadImage(_ provider: NSItemProvider) async throws -> (UIImage, Data) {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
                do {
                    if let error { throw error }
                    guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ShareFailure.empty }
                    // The provider URL is valid only for this callback. Decode here.
                    let image = try InboxAttachment.image(source: source)
                    continuation.resume(returning: (image, try FeedbackEncoder.jpeg(image)))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
