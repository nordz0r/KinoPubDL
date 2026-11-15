import Foundation
import CryptoKit

final class YTDLPService: @unchecked Sendable {
    static let progressTemplate = "download:KPDL|%(info.format_id)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s|%(progress.status)s|%(progress.fragment_index)s"
    private let tools: ToolPaths
    private let runner: ProcessRunner
    private let browser: CookieBrowser

    init(tools: ToolPaths, runner: ProcessRunner = ProcessRunner(), browser: CookieBrowser = .safari) {
        self.tools = tools
        self.runner = runner
        self.browser = browser
    }

    func beginOperation() { runner.resetCancellation() }
    func cancel() { runner.cancel() }
    func checkCancellation() throws { try runner.checkCancellation() }

    func lookup(url: String) throws -> MediaLookup {
        let url = try KinoPubAddress.validate(url)
        let data = try runner.capture(executable: tools.ytDLP, arguments: commonArguments + [
            "--dump-single-json", "--flat-playlist", "--no-progress", url,
        ])
        let info = try JSONDecoder().decode(YDLInfo.self, from: data)
        return try MediaLookup.make(from: info, inputURL: url)
    }

    func checkAuthorization(url: String) throws {
        let url = try KinoPubAddress.validate(url)
        _ = try runner.capture(executable: tools.ytDLP, arguments: commonArguments + [
            "--skip-download", "--flat-playlist", "--playlist-end", "1", "--no-progress", "--print", "id", url,
        ])
    }

    func formats(for episode: Episode) throws -> [MediaFormat] {
        try runner.checkCancellation()
        if !episode.formats.isEmpty { return episode.formats }
        let data = try runner.capture(executable: tools.ytDLP, arguments: commonArguments + [
            "--dump-single-json", "--skip-download", "--no-progress", episode.url,
        ])
        let info = try JSONDecoder().decode(YDLInfo.self, from: data)
        guard let formats = info.formats, !formats.isEmpty else { throw MediaError.noFormats(episode.title) }
        return formats
    }

    func download(
        episode: Episode,
        video: MediaFormat,
        audioIDs: Set<String>,
        destination: URL,
        onProgress: @escaping (DownloadProgress) -> Void
    ) throws -> URL {
        try runner.checkCancellation()
        let (selector, multipleAudio) = try FormatSelector.make(video: video, audioIDs: audioIDs)
        let relative = Self.outputTemplate(episode: episode, selector: selector)
        let relativeParent = (relative as NSString).deletingLastPathComponent
        let outputDirectory = relativeParent.isEmpty ? destination : destination.appendingPathComponent(relativeParent, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let outputTemplate = destination.appendingPathComponent(relative).path
        let receiptDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("KinoPubDL-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: receiptDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: receiptDirectory) }
        let receipt = receiptDirectory.appendingPathComponent("filepath.jsonl")
        var args = commonArguments + [
            "--no-overwrites", "--no-simulate", "--newline", "--progress", "-N", "1",
            "--progress-template", Self.progressTemplate,
            "--print-to-file", "after_move:%(filepath)j", receipt.path,
            "-f", selector,
        ]
        if multipleAudio { args += ["--audio-multistreams", "--merge-output-format", "mkv"] }
        args += ["-o", outputTemplate, episode.url]
        var parser = DownloadProgressParser(streamCount: video.isVideoOnly ? 1 + audioIDs.count : 1)
        try runner.stream(executable: tools.ytDLP, arguments: args) { line in
            onProgress(parser.parse(line))
        }
        try runner.checkCancellation()
        guard let data = try? Data(contentsOf: receipt),
              let path = try? JSONDecoder().decode(String.self, from: data) else {
            throw MediaError.commandFailed("yt-dlp не сообщил путь готового файла. Перекодирование и передача не запущены.")
        }
        let output = URL(fileURLWithPath: path).standardizedFileURL
        let root = destination.standardizedFileURL.path + "/"
        guard output.path.hasPrefix(root),
              !["part", "ytdl"].contains(output.pathExtension),
              let attributes = try? FileManager.default.attributesOfItem(atPath: output.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
            throw MediaError.commandFailed("Путь готового файла не прошёл проверку. Передача и перекодирование остановлены.")
        }
        return output
    }

    func transcode(file: URL, deleteOriginalAfterSuccess: Bool = false, onProgress: @escaping (EncodingProgress) -> Void, onVerifying: @escaping () -> Void) throws -> TranscodeResult {
        try Transcoder(tools: tools, runner: runner).encode(file: file, deleteOriginalAfterSuccess: deleteOriginalAfterSuccess, onProgress: onProgress, onVerifying: onVerifying)
    }

    static func outputTemplate(episode: Episode, selector: String) -> String {
        let key = "\(episode.id)|\(episode.url)|\(selector)"
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return episode.outputRelativePath.replacingOccurrences(of: ".%(ext)s", with: ".source-\(digest).%(ext)s")
    }

    func transferToVLC(file: URL, sharingURL: URL) throws -> VLCUploadResult {
        try VLCUploader.transfer(file: file, sharingURL: sharingURL, runner: runner)
    }

    private var commonArguments: [String] {
        var arguments = ["--ignore-config", "--no-warnings", "--ffmpeg-location", tools.ffmpeg.deletingLastPathComponent().path]
        if let pluginDirectory = tools.pluginDirectory { arguments += ["--plugin-dirs", pluginDirectory.path] }
        arguments += browser.arguments
        return arguments
    }
}
