import Foundation

struct SourceCleanupTests {
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KinoPubCleanupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let copy = root.appendingPathComponent("verified-copy.mp4")
        try Data([4, 5, 6]).write(to: copy)

        func fixture(_ name: String) throws -> (URL, SourceFileSnapshot) {
            let file = root.appendingPathComponent(name)
            try Data([1, 2, 3]).write(to: file)
            return (file, try SourceFileSnapshot.read(file))
        }

        let (source, expected) = try fixture("source.mp4")
        let fakeTrash = root.appendingPathComponent("fake-trash-source.mp4")
        let result = try SourceCleanup.finish(source: source, verifiedCopy: copy, expectedSource: expected, runner: ProcessRunner()) { file in
            precondition(file == source)
            try FileManager.default.moveItem(at: file, to: fakeTrash)
        }
        precondition(result == .trashed && !FileManager.default.fileExists(atPath: source.path))
        precondition(FileManager.default.fileExists(atPath: fakeTrash.path))
        precondition(FileManager.default.fileExists(atPath: copy.path))

        let (changed, changedSnapshot) = try fixture("changed.mp4")
        try Data([9, 8, 7, 6]).write(to: changed, options: .atomic)
        let changedResult = try SourceCleanup.finish(source: changed, verifiedCopy: copy, expectedSource: changedSnapshot, runner: ProcessRunner()) { _ in
            preconditionFailure("Deleted a modified source")
        }
        guard case .warning = changedResult else { preconditionFailure("Changed source was not protected") }
        precondition(FileManager.default.fileExists(atPath: changed.path))

        let (same, sameSnapshot) = try fixture("same.mp4")
        let sameResult = try SourceCleanup.finish(source: same, verifiedCopy: same, expectedSource: sameSnapshot, runner: ProcessRunner()) { _ in
            preconditionFailure("Deleted the only copy")
        }
        guard case .warning = sameResult else { preconditionFailure("Same source/copy not protected") }

        let (cancelled, cancelledSnapshot) = try fixture("cancelled.mp4")
        let runner = ProcessRunner()
        runner.cancel()
        do {
            _ = try SourceCleanup.finish(source: cancelled, verifiedCopy: copy, expectedSource: cancelledSnapshot, runner: runner) { _ in
                preconditionFailure("Deleted after cancellation")
            }
            preconditionFailure("Ignored cleanup cancellation")
        } catch is CancellationError {}
        precondition(FileManager.default.fileExists(atPath: cancelled.path))

        let (denied, deniedSnapshot) = try fixture("denied.mp4")
        let deniedResult = try SourceCleanup.finish(source: denied, verifiedCopy: copy, expectedSource: deniedSnapshot, runner: ProcessRunner()) { _ in
            throw NSError(domain: "TrashTest", code: 1)
        }
        guard case .warning = deniedResult else { preconditionFailure("Trash failure not reported") }
        precondition(FileManager.default.fileExists(atPath: denied.path))

        let (missingCopySource, missingSnapshot) = try fixture("missing-copy-source.mp4")
        let missingResult = try SourceCleanup.finish(source: missingCopySource, verifiedCopy: root.appendingPathComponent("missing.mp4"), expectedSource: missingSnapshot, runner: ProcessRunner()) { _ in
            preconditionFailure("Deleted with no output copy")
        }
        guard case .warning = missingResult else { preconditionFailure("Missing copy not protected") }
        precondition(FileManager.default.fileExists(atPath: missingCopySource.path))
        print("Source cleanup tests passed: success, changed source, same file, cancellation, trash error, missing copy. Real Trash untouched.")
    }

    static func smoke(source: URL, encoded: URL, tools: ToolPaths, root: URL) throws {
        let cleanupSource = root.appendingPathComponent("cleanup-source.mp4")
        try FileManager.default.copyItem(at: source, to: cleanupSource)
        let fakeTrash = root.appendingPathComponent("fake-trash-original.mp4")
        let deletedResult = try Transcoder(tools: tools, runner: ProcessRunner(), trash: { file in
            try FileManager.default.moveItem(at: file, to: fakeTrash)
        }).encode(file: cleanupSource, deleteOriginalAfterSuccess: true, onProgress: { _ in }, onVerifying: {})
        precondition(deletedResult.sourceDisposition == .trashed)
        precondition(!FileManager.default.fileExists(atPath: cleanupSource.path))
        precondition(FileManager.default.fileExists(atPath: deletedResult.file.path))
        precondition(FileManager.default.fileExists(atPath: fakeTrash.path))

        let reused = try Transcoder(tools: tools, runner: ProcessRunner(), trash: { _ in
            preconditionFailure("Deleted an existing HEVC source")
        }).encode(file: encoded, deleteOriginalAfterSuccess: true, onProgress: { _ in }, onVerifying: {})
        precondition(reused.reusedSource && reused.sourceDisposition == .kept)
        precondition(FileManager.default.fileExists(atPath: encoded.path))

        let cancelSource = root.appendingPathComponent("cancel-verification.mp4")
        try FileManager.default.copyItem(at: source, to: cancelSource)
        let runner = ProcessRunner()
        do {
            _ = try Transcoder(tools: tools, runner: runner, trash: { _ in
                preconditionFailure("Deleted during cancelled verification")
            }).encode(file: cancelSource, deleteOriginalAfterSuccess: true, onProgress: { _ in }, onVerifying: { runner.cancel() })
            preconditionFailure("Ignored verification cancellation")
        } catch is CancellationError {}
        precondition(FileManager.default.fileExists(atPath: cancelSource.path))

        let failureSource = root.appendingPathComponent("encoder-failure.mp4")
        try FileManager.default.copyItem(at: source, to: failureSource)
        let failureTools = ToolPaths(ytDLP: tools.ytDLP, ffmpeg: URL(fileURLWithPath: "/usr/bin/false"), ffprobe: tools.ffprobe, pluginDirectory: nil, uv: nil)
        do {
            _ = try Transcoder(tools: failureTools, runner: ProcessRunner(), trash: { _ in
                preconditionFailure("Deleted after encoder failure")
            }).encode(file: failureSource, deleteOriginalAfterSuccess: true, onProgress: { _ in }, onVerifying: {})
            preconditionFailure("Encoder failure not detected")
        } catch is MediaError {}
        precondition(FileManager.default.fileExists(atPath: failureSource.path))

        let brokenSource = root.appendingPathComponent("verification-failure.mp4")
        try FileManager.default.copyItem(at: source, to: brokenSource)
        var damaged = false
        do {
            _ = try Transcoder(tools: tools, runner: ProcessRunner(), trash: { _ in
                preconditionFailure("Deleted after output verification failure")
            }).encode(file: brokenSource, deleteOriginalAfterSuccess: true, onProgress: { _ in }, onVerifying: {
                let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
                if let staged = files.first(where: { $0.lastPathComponent.hasSuffix(".encoding.mp4") }) {
                    do {
                        try Data("broken output".utf8).write(to: staged)
                        damaged = true
                    } catch { preconditionFailure("Could not create broken test output") }
                }
            })
            preconditionFailure("Corrupted output passed verification")
        } catch is MediaError {}
        precondition(damaged && FileManager.default.fileExists(atPath: brokenSource.path))
        print("Real encoding cleanup smoke passed: opt-in cleanup, HEVC skip, cancellation, encoder failure, corrupted output. Real Trash untouched.")
    }
}
