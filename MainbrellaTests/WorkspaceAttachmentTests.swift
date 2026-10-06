import XCTest
@testable import Mainbrella

final class WorkspaceAttachmentTests: XCTestCase {
    private func temporary(_ name: String, bytes: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return url
    }

    func testDocumentPreservesBytesAndOriginalNameWithoutUsingNameAsUploadPath() throws {
        let bytes = Data([0, 255, 10, 13])
        let url = try temporary("Device notes & screenshot.PDF", bytes: bytes)
        let attachment = try WorkspaceAttachment.document(url)
        let attempt = InboxAttempt(draft: InboxDraft(instruction: "Review this", text: "", attachment: attachment),
                                   workspace: APIClientTests.workspace)
        XCTAssertEqual(attachment.data, bytes)
        XCTAssertEqual(attempt.message.attachmentName, url.lastPathComponent)
        XCTAssertEqual(attempt.message.attachment, "message-\(attempt.id).pdf")
        XCTAssertEqual(attempt.message.source, "ios-file")
        XCTAssertEqual(attempt.message.generation, APIClientTests.workspace.createdAt)
    }

    func testBoundaryAndEmptyFileAreAcceptedButOversizeAndDirectoriesAreRejected() throws {
        for size in [0, 1_048_576] {
            let url = try temporary("file.txt", bytes: Data(count: size))
            XCTAssertEqual(try WorkspaceAttachment.document(url).data.count, size)
        }
        let oversized = try temporary("large.txt", bytes: Data(count: 1_048_577))
        XCTAssertThrowsError(try WorkspaceAttachment.document(oversized)) { error in
            XCTAssertEqual(error as? AttachmentFailure, .tooLarge)
        }
        XCTAssertThrowsError(try WorkspaceAttachment.document(oversized.deletingLastPathComponent())) { error in
            XCTAssertEqual(error as? AttachmentFailure, .notAFile)
        }
    }

    func testUnsafeAndMissingExtensionsUseBinarySuffix() throws {
        for name in ["README", "notes.bad ext", "notes.絵"] {
            let url = try temporary(name, bytes: Data())
            XCTAssertEqual(try WorkspaceAttachment.document(url).suffix, "bin")
        }
    }

    func testCameraPhotoIsResizedWithOrientationAndKeptWithinUploadLimit() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let original = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 1000), format: format).image { context in
            UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 3000, height: 1000))
        }
        let attachment = try WorkspaceAttachment.photo(original, source: "ios-camera")
        let image = try XCTUnwrap(UIImage(data: attachment.data))
        XCTAssertEqual(image.size.width, 2048)
        XCTAssertLessThanOrEqual(attachment.data.count, 1_048_576)
        XCTAssertEqual(attachment.source, "ios-camera")
        let rotated = UIImage(cgImage: try XCTUnwrap(original.cgImage), scale: 1, orientation: .right)
        let portrait = try XCTUnwrap(UIImage(data: WorkspaceAttachment.photo(rotated, source: "ios-camera").data))
        XCTAssertEqual(portrait.size.height, 2048)
        XCTAssertLessThan(portrait.size.width, portrait.size.height)
    }

    func testOldInboxMetadataStillDecodes() throws {
        let old = Data(#"{"version":1,"createdAt":"now","workspaceID":"small","generation":"exact","source":"ios-text","instruction":"Review","text":"","attachment":null}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(InboxMessage.self, from: old).attachmentName)
    }
}
