import Darwin
import Foundation

@main
struct StepImportStagedFileTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StepImportStagedFileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("source.step")
        try Data("0123456789".utf8).write(to: sourceURL)
        let source = try FileHandle(forReadingFrom: sourceURL)
        defer { try? source.close() }
        let sourceSnapshot = try StepImportSourceDescriptor.validate(
            source,
            maximumBytes: 10
        )
        expect(
            sourceSnapshot.byteCount == 10,
            "a regular file should report its exact logical byte count"
        )
        do {
            _ = try StepImportSourceDescriptor.validate(source, maximumBytes: 9)
            fail("a regular file above the source ceiling was accepted")
        } catch StepImportSourceDescriptorError.tooLarge(
            actualBytes: 10,
            maximumBytes: 9
        ) {
            // Expected before staging or reading source content.
        } catch {
            fail("an oversized regular file returned the wrong error: \(error)")
        }
        let sourceWriter = try FileHandle(forWritingTo: sourceURL)
        try sourceWriter.seekToEnd()
        try sourceWriter.write(contentsOf: Data("x".utf8))
        try sourceWriter.close()
        do {
            try StepImportSourceDescriptor.requireUnchanged(
                source,
                from: sourceSnapshot,
                maximumBytes: 100
            )
            fail("a source mutation after descriptor capture was accepted")
        } catch StepImportSourceDescriptorError.changed {
            // Expected before OCCT sees the staged copy.
        } catch {
            fail("a changed source returned the wrong error: \(error)")
        }

        var pipeDescriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.pipe(&pipeDescriptors) == 0 else {
            fail("could not create the descriptor-validation pipe")
        }
        let pipeReader = FileHandle(
            fileDescriptor: pipeDescriptors[0],
            closeOnDealloc: true
        )
        let pipeWriter = FileHandle(
            fileDescriptor: pipeDescriptors[1],
            closeOnDealloc: true
        )
        defer {
            try? pipeReader.close()
            try? pipeWriter.close()
        }
        do {
            _ = try StepImportSourceDescriptor.validate(
                pipeReader,
                maximumBytes: 512 * 1_024 * 1_024
            )
            fail("a pipe descriptor was accepted as a STEP source")
        } catch StepImportSourceDescriptorError.unsupportedFileType {
            // Expected before the service can enter a blocking read.
        } catch {
            fail("a pipe descriptor returned the wrong error: \(error)")
        }

        let active = try StepImportStagedFile.prepare(sourceExtension: "STEP", in: root)
        try Data("active".utf8).write(to: active.fileURL)
        StepImportStagedFile.reapAbandoned(in: root)
        expect(FileManager.default.fileExists(atPath: active.fileURL.path),
               "reaper removed an actively locked STEP copy")
        expect(FileManager.default.fileExists(atPath: active.lockURL.path),
               "reaper removed an active sidecar lock")

        let abandonedURL = root
            .appendingPathComponent("\(StepImportStagedFile.artifactPrefix)abandoned")
            .appendingPathExtension("stp")
        let abandonedLockURL = abandonedURL.appendingPathExtension("lock")
        try Data("abandoned".utf8).write(to: abandonedURL)
        FileManager.default.createFile(atPath: abandonedLockURL.path, contents: Data())

        StepImportStagedFile.reapAbandoned(in: root)
        expect(!FileManager.default.fileExists(atPath: abandonedURL.path),
               "reaper retained an abandoned STEP copy")
        expect(!FileManager.default.fileExists(atPath: abandonedLockURL.path),
               "reaper retained an abandoned sidecar lock")

        active.cleanup()
        active.cleanup()
        expect(!FileManager.default.fileExists(atPath: active.fileURL.path),
               "normal cleanup retained the staged STEP copy")
        expect(!FileManager.default.fileExists(atPath: active.lockURL.path),
               "normal cleanup retained the sidecar lock")

        print("Step import staging tests passed")
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("FAIL: \(message)\n", stderr)
        exit(EXIT_FAILURE)
    }
}
