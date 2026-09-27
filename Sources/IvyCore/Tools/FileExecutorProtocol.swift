import Foundation

/// Supported file operation actions.
public enum FileAction: String, Sendable, Codable, CaseIterable {
    case read
    case write
    case delete
}

/// Structured outcome of a file operation.
public struct FileOpResult: Sendable, Equatable {
    public let action: FileAction
    public let path: String
    public let content: String?
    public let bytesAffected: Int
    public let message: String

    public init(
        action: FileAction,
        path: String,
        content: String? = nil,
        bytesAffected: Int = 0,
        message: String
    ) {
        self.action = action
        self.path = path
        self.content = content
        self.bytesAffected = bytesAffected
        self.message = message
    }
}

/// Errors occurring during file operations.
public enum FileOpError: Error, LocalizedError, Equatable, Sendable {
    case fileNotFound(String)
    case permissionDenied(String)
    case fileTooLarge(actual: Int, maxAllowed: Int)
    case pathOutOfBounds(String)
    case isDirectory(String)
    case parentDirectoryNotFound(String)
    case ioError(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "File not found: '\(path)'"
        case .permissionDenied(let path):
            return "Permission denied accessing: '\(path)'"
        case .fileTooLarge(let actual, let maxAllowed):
            return "File exceeds maximum read size limit (\(actual) bytes > \(maxAllowed) bytes)."
        case .pathOutOfBounds(let path):
            return "Path '\(path)' is outside the permitted filesystem scope."
        case .isDirectory(let path):
            return "Path '\(path)' is a directory. Directory operations are not permitted in this phase."
        case .parentDirectoryNotFound(let path):
            return "Parent directory does not exist for: '\(path)'"
        case .ioError(let msg):
            return "File I/O error: \(msg)"
        }
    }
}

/// Abstraction for filesystem operations.
/// Allows mock-based unit testing without touching the actual filesystem.
public protocol FileExecutorProtocol: Sendable {
    /// Reads the content of a file at the given path.
    func readFile(at path: String) async throws -> FileOpResult

    /// Writes the content to a file at the given path.
    func writeFile(at path: String, content: String) async throws -> FileOpResult

    /// Deletes a file at the given path.
    func deleteFile(at path: String) async throws -> FileOpResult
}

/// Production implementation of FileExecutorProtocol using Foundation and FileManager.
public final class SystemFileExecutor: FileExecutorProtocol, Sendable {
    /// Default maximum file size allowed for reading (1 MB).
    public static let defaultMaxReadSize: Int = 1_048_576

    public let maxReadSize: Int

    public init(maxReadSize: Int = defaultMaxReadSize) {
        self.maxReadSize = maxReadSize
    }

    public func readFile(at path: String) async throws -> FileOpResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false

        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            throw FileOpError.fileNotFound(path)
        }

        if isDir.boolValue {
            throw FileOpError.isDirectory(path)
        }

        let url = URL(fileURLWithPath: path)

        do {
            let attributes = try fm.attributesOfItem(atPath: path)
            let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
            if fileSize > maxReadSize {
                throw FileOpError.fileTooLarge(actual: fileSize, maxAllowed: maxReadSize)
            }

            let data = try Data(contentsOf: url)
            let content = String(decoding: data, as: UTF8.self)
            return FileOpResult(
                action: .read,
                path: path,
                content: content,
                bytesAffected: data.count,
                message: content
            )
        } catch let err as FileOpError {
            throw err
        } catch let nsErr as NSError {
            if nsErr.domain == NSCocoaErrorDomain && nsErr.code == NSFileReadNoSuchFileError {
                throw FileOpError.fileNotFound(path)
            } else if nsErr.domain == NSCocoaErrorDomain && nsErr.code == NSFileReadNoPermissionError {
                throw FileOpError.permissionDenied(path)
            } else {
                throw FileOpError.ioError(nsErr.localizedDescription)
            }
        }
    }

    public func writeFile(at path: String, content: String) async throws -> FileOpResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false

        if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            throw FileOpError.isDirectory(path)
        }

        let parentDir = (path as NSString).deletingLastPathComponent
        guard !parentDir.isEmpty, fm.fileExists(atPath: parentDir, isDirectory: &isDir), isDir.boolValue else {
            throw FileOpError.parentDirectoryNotFound(parentDir)
        }

        let url = URL(fileURLWithPath: path)
        let data = Data(content.utf8)

        do {
            try data.write(to: url, options: .atomic)
            return FileOpResult(
                action: .write,
                path: path,
                content: nil,
                bytesAffected: data.count,
                message: "Successfully wrote \(data.count) bytes to '\(path)'."
            )
        } catch let nsErr as NSError {
            if nsErr.domain == NSCocoaErrorDomain && nsErr.code == NSFileWriteNoPermissionError {
                throw FileOpError.permissionDenied(path)
            } else {
                throw FileOpError.ioError(nsErr.localizedDescription)
            }
        }
    }

    public func deleteFile(at path: String) async throws -> FileOpResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false

        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            throw FileOpError.fileNotFound(path)
        }

        if isDir.boolValue {
            throw FileOpError.isDirectory(path)
        }

        do {
            try fm.removeItem(atPath: path)
            return FileOpResult(
                action: .delete,
                path: path,
                content: nil,
                bytesAffected: 0,
                message: "Successfully deleted file '\(path)'."
            )
        } catch let nsErr as NSError {
            if nsErr.domain == NSCocoaErrorDomain && (nsErr.code == NSFileNoSuchFileError || nsErr.code == NSFileReadNoSuchFileError) {
                throw FileOpError.fileNotFound(path)
            } else if nsErr.domain == NSCocoaErrorDomain && nsErr.code == NSFileWriteNoPermissionError {
                throw FileOpError.permissionDenied(path)
            } else {
                throw FileOpError.ioError(nsErr.localizedDescription)
            }
        }
    }
}
