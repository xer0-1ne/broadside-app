import Foundation
import CoreTransferable
import UniformTypeIdentifiers

/// A file picked from the photo library, received as a file rather than as
/// bytes.
///
/// `loadTransferable(type: Data.self)` is the obvious way to get a photograph
/// out of `PhotosPicker`, and it is the wrong one here. It decodes the whole
/// image into memory, so a 300MB frame becomes 300MB of resident data in a
/// process the system will terminate for far less. A `FileRepresentation` hands
/// over a URL and the copy below is file to file, which means the memory cost
/// of importing a huge photograph is the same as a small one.
struct PickedFile: Transferable, Sendable {
    let url: URL

    var filename: String { url.lastPathComponent }

    /// What to tell the server the file is. Derived from the extension the
    /// system gave the export, which is trustworthy in a way a client-supplied
    /// type would not be, and checked again by Broadside against the actual
    /// bytes before anything is stored.
    var contentType: String {
        let ext = url.pathExtension
        if let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .image) { picked in
            SentTransferredFile(picked.url)
        } importing: { received in
            // The received file is deleted as soon as this closure returns, so
            // it has to be copied somewhere the upload can still find it
            // minutes later.
            let name = received.file.lastPathComponent
            let destination = FileManager.default.temporaryDirectory
                .appending(path: "picked-\(UUID().uuidString)-\(name)")

            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: received.file, to: destination)

            return PickedFile(url: destination)
        }
    }
}
