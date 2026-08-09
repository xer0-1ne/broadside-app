import Foundation

/// Builds a multipart body on disk rather than in memory.
///
/// This exists because of what people put in Broadside posts. A stacked
/// astrophotography frame is routinely several hundred megabytes, and building
/// its request body as a `Data` means holding the whole file plus the whole
/// body — twice the file — in a process the system will kill for far less on a
/// phone. Streaming it into a temporary file costs a copy on disk and makes the
/// memory cost of a 2GB upload the same as a 2MB one.
///
/// It is also what makes a background upload possible at all: URLSession's
/// background configuration only accepts a body as a file, never as data.
enum MultipartBody {
    /// The form field name the server reads. `r.FormFile("file")` in
    /// `internal/server/media.go`.
    static let fieldName = "file"

    static func make(fileURL: URL, filename: String, contentType: String, boundary: String) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "upload-\(UUID().uuidString).multipart")

        FileManager.default.createFile(atPath: destination.path, contents: nil)

        guard let out = try? FileHandle(forWritingTo: destination) else {
            throw APIError.transport("This device would not allow a temporary file to be written.")
        }
        defer { try? out.close() }

        let header = """
        --\(boundary)\r
        Content-Disposition: form-data; name="\(fieldName)"; filename="\(filename.headerSafe)"\r
        Content-Type: \(contentType)\r
        \r

        """
        try out.write(contentsOf: Data(header.utf8))

        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }

        // A megabyte at a time. Large enough that the syscall overhead does not
        // matter, small enough that the peak footprint is a rounding error next
        // to the photograph itself.
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }

        try out.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        return destination
    }
}

private extension String {
    /// A filename with a quote or a newline in it would end the header early
    /// and let the rest be read as more of the request. The names here come off
    /// somebody's own camera roll rather than from a stranger, but a header
    /// built by concatenation is the habit worth not having.
    var headerSafe: String {
        replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }
}
