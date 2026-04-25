import Foundation
import Darwin

enum AtomicFileWriter {
    static func write(data: Data, to destinationURL: URL) throws {
        let directoryURL = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let tempURL = directoryURL.appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = open(tempURL.path, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }

        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var written = 0
                while written < rawBuffer.count {
                    let result = Darwin.write(fd, baseAddress.advanced(by: written), rawBuffer.count - written)
                    if result < 0 {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    written += result
                }
            }

            guard fsync(fd) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
            close(fd)

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: destinationURL)
            }
        } catch {
            close(fd)
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }
}
