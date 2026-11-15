import Foundation

struct TranscodeResult {
    let file: URL
    let originalBytes: Double
    let encodedBytes: Double
    let reusedSource: Bool
    var sourceDisposition: SourceDisposition = .kept

    var summary: String {
        if reusedSource { return "Источник уже H.265 — повторное кодирование и удаление пропущены. Оригинал сохранён." }
        let change = originalBytes > 0 ? 100 * (1 - encodedBytes / originalBytes) : 0
        return "До: \(ProgressText.bytes(originalBytes)) → после: \(ProgressText.bytes(encodedBytes)) (\(String(format: "%+.1f", -change))%). \(sourceDisposition.message)"
    }
}

struct ProbeInfo: Decodable {
    struct Format: Decodable {
        let duration: String
        let size: String
    }
    struct Stream: Decodable {
        let codec_type: String
        let codec_name: String?
        let width: Int?
        let height: Int?
    }
    let format: Format
    let streams: [Stream]

    var duration: Double { Double(format.duration) ?? 0 }
    var size: Double { Double(format.size) ?? 0 }
    var video: Stream? { streams.first { $0.codec_type == "video" } }
    var audioCodecs: [String] { streams.filter { $0.codec_type == "audio" }.map { $0.codec_name ?? "unknown" } }
}

final class Transcoder {
    private let tools: ToolPaths
    private let runner: ProcessRunner
    private let trash: (URL) throws -> Void

    init(tools: ToolPaths, runner: ProcessRunner, trash: @escaping (URL) throws -> Void = SourceCleanup.moveToTrash) {
        self.tools = tools
        self.runner = runner
        self.trash = trash
    }

    func encode(
        file: URL,
        deleteOriginalAfterSuccess: Bool = false,
        onProgress: @escaping (EncodingProgress) -> Void,
        onVerifying: @escaping () -> Void
    ) throws -> TranscodeResult {
        try runner.checkCancellation()
        let source = try probe(file)
        guard source.duration.isFinite, source.duration > 0, source.size > 0, let sourceVideo = source.video else {
            throw MediaError.commandFailed("Не удалось определить длительность или видеопоток для перекодирования.")
        }
        if sourceVideo.codec_name == "hevc" {
            return TranscodeResult(file: file, originalBytes: source.size, encodedBytes: source.size, reusedSource: true)
        }
        let originalSnapshot = deleteOriginalAfterSuccess ? try SourceFileSnapshot.read(file) : nil
        let directory = file.deletingLastPathComponent()
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        let free = (attributes[.systemFreeSize] as? NSNumber)?.doubleValue ?? 0
        guard free > source.size * 2 + 64_000_000 else {
            throw MediaError.commandFailed("Недостаточно места для безопасного перекодирования. Нужно свободно около \(ProgressText.bytes(source.size * 2 + 64_000_000)); оригинал удаляться не будет.")
        }
        let ext = file.pathExtension.lowercased() == "mp4" ? "mp4" : "mkv"
        let stem = file.deletingPathExtension().lastPathComponent
        let output = Self.availableOutput(directory: directory, stem: stem, ext: ext)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).encoding.\(ext)")
        defer { try? FileManager.default.removeItem(at: temporary) }

        var args = [
            "-hide_banner", "-loglevel", "warning", "-nostdin", "-n",
            "-i", file.path,
            "-map", "0:v:0", "-map", "0:a?", "-map", "0:s?", "-map_metadata", "0",
            "-c", "copy", "-c:v:0", "libx265", "-crf", "28", "-preset", "medium",
        ]
        if ext == "mp4" { args += ["-tag:v:0", "hvc1", "-movflags", "+faststart"] }
        args += ["-progress", "pipe:2", "-nostats", "-stats_period", "0.5", temporary.path]
        var parser = EncodingProgressParser(duration: source.duration)
        try runner.stream(executable: tools.ffmpeg, arguments: args) { line in
            if let update = parser.parse(line) { onProgress(update) }
        }
        try runner.checkCancellation()
        onVerifying()
        let encoded = try probe(temporary)
        guard encoded.video?.codec_name == "hevc",
              encoded.video?.width == sourceVideo.width,
              encoded.video?.height == sourceVideo.height,
              abs(encoded.duration - source.duration) < 0.5,
              encoded.audioCodecs == source.audioCodecs,
              encoded.size > 0 else {
            throw MediaError.commandFailed("Проверка H.265-копии не прошла. Исходный файл сохранён без изменений.")
        }
        if deleteOriginalAfterSuccess {
            try runner.stream(executable: tools.ffmpeg, arguments: [
                "-hide_banner", "-v", "error", "-xerror", "-nostdin", "-i", temporary.path,
                "-map", "0:v:0", "-map", "0:a?", "-f", "null", "-",
            ], onLine: { _ in })
        }
        try runner.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: output)
        let disposition: SourceDisposition
        if let originalSnapshot {
            disposition = try SourceCleanup.finish(source: file, verifiedCopy: output, expectedSource: originalSnapshot, runner: runner, trash: trash)
        } else {
            disposition = .kept
        }
        return TranscodeResult(file: output, originalBytes: source.size, encodedBytes: encoded.size, reusedSource: false, sourceDisposition: disposition)
    }

    private func probe(_ file: URL) throws -> ProbeInfo {
        let data = try runner.capture(executable: tools.ffprobe, arguments: [
            "-v", "error", "-show_entries", "format=duration,size:stream=codec_type,codec_name,width,height", "-of", "json", file.path,
        ])
        return try JSONDecoder().decode(ProbeInfo.self, from: data)
    }

    static func availableOutput(directory: URL, stem: String, ext: String) -> URL {
        var candidate = directory.appendingPathComponent("\(stem).h265-crf28.\(ext)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem).h265-crf28-\(suffix).\(ext)")
            suffix += 1
        }
        return candidate
    }
}
