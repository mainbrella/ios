import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceAttachment: Equatable {
    let data: Data
    let name: String
    let suffix: String
    let source: String

    static func document(_ url: URL) throws -> Self {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Self, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
            result = Result {
                let values = try readableURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true else { throw AttachmentFailure.notAFile }
                guard (values.fileSize ?? 0) <= 1_048_576 else { throw AttachmentFailure.tooLarge }
                let handle = try FileHandle(forReadingFrom: readableURL)
                defer { try? handle.close() }
                var bytes = Data()
                while bytes.count <= 1_048_576 {
                    let chunk = try handle.read(upToCount: min(65_536, 1_048_577 - bytes.count)) ?? Data()
                    if chunk.isEmpty { break }
                    bytes.append(chunk)
                }
                guard bytes.count <= 1_048_576 else { throw AttachmentFailure.tooLarge }
                let ext = readableURL.pathExtension.lowercased()
                let safe = !ext.isEmpty && ext.count <= 16 && ext.utf8.allSatisfy {
                    (48...57).contains($0) || (97...122).contains($0)
                }
                return Self(data: bytes, name: url.lastPathComponent,
                            suffix: safe ? ext : "bin", source: "ios-file")
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw AttachmentFailure.notAFile }
        return try result.get()
    }

    static func photo(_ image: UIImage, source: String) throws -> Self {
        let ratio = min(1, 2048 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let reduced = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return Self(data: try FeedbackEncoder.jpeg(reduced), name: source == "ios-camera" ? "Camera photo.jpg" : "Photo.jpg",
                    suffix: "jpg", source: source)
    }
}

enum AttachmentFailure: LocalizedError {
    case tooLarge, notAFile
    var errorDescription: String? {
        switch self {
        case .tooLarge: return "Files must be 1 MiB or smaller. Choose a smaller file."
        case .notAFile: return "Choose a single file. Folders can't be attached."
        }
    }
}

/// Freeze metadata and attachment identity across an unchanged upload retry.
struct InboxDraft: Equatable {
    let instruction: String
    let text: String
    let attachment: WorkspaceAttachment?
}

struct InboxAttempt {
    let draft: InboxDraft
    let id: String
    let message: InboxMessage

    init(draft: InboxDraft, workspace: Workspace) {
        self.draft = draft
        let id = UUID().uuidString.lowercased()
        self.id = id
        message = InboxMessage(version: 1, createdAt: ISO8601DateFormatter().string(from: Date()),
            workspaceID: workspace.id, generation: workspace.createdAt,
            source: draft.attachment?.source ?? "ios-text", instruction: draft.instruction,
            text: draft.text, attachment: draft.attachment.map { "message-\(id).\($0.suffix)" },
            attachmentName: draft.attachment?.name)
    }
}

struct CameraCapture: UIViewControllerRepresentable {
    let complete: (UIImage?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(complete: complete) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let complete: (UIImage?) -> Void
        init(complete: @escaping (UIImage?) -> Void) { self.complete = complete }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { complete(nil) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            complete(info[.originalImage] as? UIImage)
        }
    }
}
