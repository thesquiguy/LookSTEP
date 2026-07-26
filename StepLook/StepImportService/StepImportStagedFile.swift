import Darwin
import Foundation

enum StepImportSourceDescriptorError: Error, Equatable {
    case inspectionFailed(Int32)
    case negativeSize
    case unsupportedFileType
    case changed
    case tooLarge(actualBytes: Int64, maximumBytes: Int64)
}

struct StepImportSourceDescriptorSnapshot: Equatable, Sendable {
    let byteCount: Int64
    let device: UInt64
    let inode: UInt64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64
}

enum StepImportSourceDescriptor {
    static func validate(
        _ sourceFile: FileHandle,
        maximumBytes: Int64
    ) throws -> StepImportSourceDescriptorSnapshot {
        var status = stat()
        guard Darwin.fstat(sourceFile.fileDescriptor, &status) == 0 else {
            throw StepImportSourceDescriptorError.inspectionFailed(errno)
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw StepImportSourceDescriptorError.unsupportedFileType
        }
        guard status.st_size >= 0 else {
            throw StepImportSourceDescriptorError.negativeSize
        }
        guard status.st_size <= maximumBytes else {
            throw StepImportSourceDescriptorError.tooLarge(
                actualBytes: status.st_size,
                maximumBytes: maximumBytes
            )
        }
        return StepImportSourceDescriptorSnapshot(
            byteCount: status.st_size,
            device: UInt64(bitPattern: Int64(status.st_dev)),
            inode: UInt64(status.st_ino),
            modificationSeconds: Int64(status.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec),
            changeSeconds: Int64(status.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(status.st_ctimespec.tv_nsec)
        )
    }

    static func requireUnchanged(
        _ sourceFile: FileHandle,
        from expected: StepImportSourceDescriptorSnapshot,
        maximumBytes: Int64
    ) throws {
        let current = try validate(sourceFile, maximumBytes: maximumBytes)
        guard current == expected else {
            throw StepImportSourceDescriptorError.changed
        }
    }
}

/// Owns the service-private STEP copy used by OCCT.
///
/// Normal completion removes both artifacts. If the service deliberately exits
/// during non-cooperative OCCT work, the kernel releases the sidecar lock and
/// the next service process reaps the abandoned copy before accepting work.
final class StepImportStagedFile {
    static let artifactPrefix = "StepLook-Import-"

    let fileURL: URL
    let lockURL: URL

    private let cleanupLock = NSLock()
    private var lockDescriptor: Int32

    private init(fileURL: URL, lockURL: URL, lockDescriptor: Int32) {
        self.fileURL = fileURL
        self.lockURL = lockURL
        self.lockDescriptor = lockDescriptor
    }

    static func prepare(
        sourceExtension: String,
        in directory: URL = FileManager.default.temporaryDirectory
    ) throws -> StepImportStagedFile {
        reapAbandoned(in: directory)

        let fileExtension = sourceExtension.lowercased() == "stp" ? "stp" : "step"
        let fileURL = directory
            .appendingPathComponent("\(artifactPrefix)\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        let lockURL = fileURL.appendingPathExtension("lock")
        let creatingURL = lockURL.appendingPathExtension("creating")
        let descriptor = Darwin.open(
            creatingURL.path,
            O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            _ = Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: creatingURL)
            throw POSIXError(POSIXErrorCode(rawValue: lockError) ?? .EIO)
        }

        do {
            try FileManager.default.moveItem(at: creatingURL, to: lockURL)
        } catch {
            _ = flock(descriptor, LOCK_UN)
            _ = Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: creatingURL)
            throw error
        }
        return StepImportStagedFile(
            fileURL: fileURL,
            lockURL: lockURL,
            lockDescriptor: descriptor
        )
    }

    static func reapAbandoned(
        in directory: URL = FileManager.default.temporaryDirectory
    ) {
        guard let artifacts = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for lockURL in artifacts where isLockArtifact(lockURL) {
            reap(lockURL: lockURL)
        }

        // A data file without its sidecar can only be an interrupted creation
        // or cleanup. Active staging objects publish and hold the lock first.
        for fileURL in artifacts where isSTEPArtifact(fileURL) {
            let lockURL = fileURL.appendingPathExtension("lock")
            if !FileManager.default.fileExists(atPath: lockURL.path) {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    func cleanup() {
        let descriptor = cleanupLock.withLock { () -> Int32 in
            let descriptor = lockDescriptor
            lockDescriptor = -1
            return descriptor
        }
        guard descriptor >= 0 else { return }

        try? FileManager.default.removeItem(at: fileURL)
        _ = flock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
        try? FileManager.default.removeItem(at: lockURL)
    }

    deinit {
        cleanup()
    }

    private static func isLockArtifact(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix(artifactPrefix)
            && (url.pathExtension == "lock" || url.pathExtension == "creating")
    }

    private static func isSTEPArtifact(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix(artifactPrefix)
            && (url.pathExtension == "step" || url.pathExtension == "stp")
    }

    private static func reap(lockURL: URL) {
        let descriptor = Darwin.open(lockURL.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            _ = Darwin.close(descriptor)
            return
        }

        if lockURL.pathExtension == "lock" {
            try? FileManager.default.removeItem(at: lockURL.deletingPathExtension())
        }
        try? FileManager.default.removeItem(at: lockURL)
        _ = flock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
