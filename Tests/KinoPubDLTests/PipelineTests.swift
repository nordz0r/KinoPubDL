import Foundation

struct PipelineTests {
    static func run() throws {
        downloadBytesAcrossStreams()
        unknownDownloadSize()
        encodingTimeAndETA()
        try cancellationBetweenStages()
        try outputNameDoesNotOverwrite()
        selectionSpecificDownloadNames()
        try cancelDuringVLCPreparation()
        try selectAndSendLocalFiles()
        sharingURLValidation()
        print("Pipeline progress and file-transfer tests passed (9 groups).")
        try SourceCleanupTests.run()
    }

    private static func downloadBytesAcrossStreams() {
        var parser = DownloadProgressParser(streamCount: 2)
        let first = parser.parse("KPDL|hls-720p|50000000|100000000|NA|2000000|25|downloading|1")
        precondition(first.stage == .downloading && first.fraction == 0.25)
        precondition(first.detail.contains("Скачано") && first.detail.contains("1/2"))
        _ = parser.parse("KPDL|hls-720p|100000000|100000000|NA|2000000|0|finished|100")
        let audio = parser.parse("KPDL|audio-720-1|10000000|20000000|NA|1000000|10|downloading|1")
        precondition(audio.fraction == 0.75 && audio.detail.contains("2/2"))
        let finish = parser.parse("KPDL|audio-720-1|20000000|20000000|NA|1000000|0|finished|20")
        precondition(finish.fraction == 1)
        precondition(parser.completedBytes == 120000000)
        let merging = parser.parse("[Merger] Merging formats")
        precondition(merging.stage == .merging && merging.fraction == nil)
    }

    private static func unknownDownloadSize() {
        var parser = DownloadProgressParser(streamCount: 1)
        let unknown = parser.parse("KPDL|hls-720p|1000000|NA|NA|NA|NA|downloading|1")
        precondition(unknown.fraction == nil && unknown.detail.contains("неизвестен"))
        let estimate = parser.parse("KPDL|hls-720p|1000000|NA|2000000|NA|NA|downloading|2")
        precondition(estimate.fraction == 0.5 && estimate.detail.contains("≈"))
    }

    private static func encodingTimeAndETA() {
        var parser = EncodingProgressParser(duration: 120)
        _ = parser.parse("out_time_us=60000000")
        _ = parser.parse("speed=2.0x")
        _ = parser.parse("total_size=2000000")
        let update = parser.parse("progress=continue")!
        precondition(update.fraction == 0.5)
        precondition(update.detail.contains("01:00 из 02:00"))
        precondition(update.detail.contains("00:30"))
        _ = parser.parse("out_time_us=120000000")
        precondition(parser.parse("progress=end")!.fraction < 1)
        _ = parser.parse("speed=N/A")
        precondition(!parser.parse("progress=continue")!.detail.contains("осталось"))
    }

    private static func cancellationBetweenStages() throws {
        let runner = ProcessRunner()
        runner.cancel()
        do {
            _ = try runner.capture(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
            preconditionFailure("Cancelled pipeline started another process")
        } catch is CancellationError {}
        runner.resetCancellation()
        _ = try runner.capture(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { runner.cancel() }
        do {
            try runner.stream(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], onLine: { _ in })
            preconditionFailure("Active process did not cancel")
        } catch is CancellationError {}
        do {
            try runner.checkCancellation()
            preconditionFailure("Pipeline lost cancellation between stages")
        } catch is CancellationError {}
    }

    private static func outputNameDoesNotOverwrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KinoPubOutputTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("movie.h265-crf28.mp4")
        try Data([1, 2, 3]).write(to: first)
        let second = Transcoder.availableOutput(directory: root, stem: "movie", ext: "mp4")
        precondition(second.lastPathComponent == "movie.h265-crf28-2.mp4")
        precondition(tryUnchanged(first))
    }

    private static func selectionSpecificDownloadNames() {
        let episode = Episode(id: "movie", title: "same title", url: "https://kino.watch/item/view/1", series: nil, seasonNumber: nil, episodeNumber: nil, formats: [])
        let first = YTDLPService.outputTemplate(episode: episode, selector: "hls-720p+audio-720-1")
        let otherQuality = YTDLPService.outputTemplate(episode: episode, selector: "hls-1080p+audio-1080-1")
        let otherAudio = YTDLPService.outputTemplate(episode: episode, selector: "hls-720p+audio-720-2")
        precondition(first != otherQuality && first != otherAudio)
        precondition(first == YTDLPService.outputTemplate(episode: episode, selector: "hls-720p+audio-720-1"))
    }

    private static func cancelDuringVLCPreparation() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CancellationPageProtocol.self]
        let session = URLSession(configuration: configuration)
        let runner = ProcessRunner()
        CancellationPageProtocol.onStart = { runner.cancel() }
        defer {
            session.invalidateAndCancel()
            CancellationPageProtocol.onStart = nil
        }
        do {
            _ = try VLCUploader.transfer(file: URL(fileURLWithPath: "/nonexistent-local-test-file"), sharingURL: URL(string: "http://vlc-test.invalid/")!, runner: runner, session: session)
            preconditionFailure("Upload preparation ignored cancellation")
        } catch is CancellationError {}
    }

    private static func sharingURLValidation() {
        precondition(VLCUploader.sharingURL(from: "192.168.30.22")?.absoluteString == "http://192.168.30.22")
        precondition(VLCUploader.sharingURL(from: "http://ipad.local:8080/")?.port == 8080)
        precondition(VLCUploader.sharingURL(from: "") == nil)
        precondition(VLCUploader.sharingURL(from: "file:///tmp/video.mp4") == nil)
        precondition(VLCUploader.sharingURL(from: "http://user:password@ipad.local/") == nil)
    }

    private static func selectAndSendLocalFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KinoPubLocalTransfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("video one.mp4")
        let second = root.appendingPathComponent("another video.mkv")
        try Data([1, 2, 3]).write(to: first)
        try Data([4, 5]).write(to: second)
        let files = try LocalTransferFile.selected([first, second, first])
        precondition(files.count == 2 && files[0].size == 3 && files[1].size == 2)
        do {
            _ = try LocalTransferFile.selected([root])
            preconditionFailure("Selected a directory instead of a file")
        } catch is MediaError {}
        let runner = ProcessRunner()
        let target = URL(string: "http://vlc-test.invalid/")!
        var sent: [URL] = []
        let result = try LocalFileTransfer.send(files: files, sharingURL: target, runner: runner, transfer: { file, url, _ in
            precondition(url == target)
            sent.append(file)
            return .uploaded
        }, onFile: { index, file in precondition(file == files[index]) }, onManual: { _, _ in preconditionFailure("Unexpected fallback") })
        precondition(result.uploaded == 2 && result.manual == 0 && sent == [first, second])
        let original = try Data(contentsOf: first)
        precondition(original == Data([1, 2, 3]))
        sent = []
        do {
            _ = try LocalFileTransfer.send(files: files, sharingURL: target, runner: runner, transfer: { file, _, runner in
                sent.append(file)
                runner.cancel()
                return .uploaded
            }, onFile: { _, _ in }, onManual: { _, _ in })
            preconditionFailure("File queue did not cancel")
        } catch is CancellationError {}
        precondition(sent == [first])
    }

    private static func tryUnchanged(_ file: URL) -> Bool { (try? Data(contentsOf: file)) == Data([1, 2, 3]) }

    static func smoke() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KinoPubPipelineSmoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("sample.mp4")
        guard let tools = ToolLocator.locate() else {
            throw MediaError.commandFailed("Integration tests require yt-dlp and ffmpeg in Homebrew or ~/.local/bin.")
        }
        let runner = ProcessRunner()
        try runner.stream(executable: tools.ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-nostdin", "-n",
            "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
            "-t", "12", "-c:v", "libx264", "-c:a", "aac", source.path,
        ], onLine: { _ in })
        let original = try Data(contentsOf: source)
        var progressUpdates = 0
        var verified = false
        let encoded = try Transcoder(tools: tools, runner: runner).encode(file: source, onProgress: { update in
            progressUpdates += 1
            precondition(update.fraction >= 0 && update.fraction < 1)
        }, onVerifying: { verified = true })
        precondition(progressUpdates > 0 && verified)
        precondition(FileManager.default.fileExists(atPath: encoded.file.path))
        precondition(encoded.sourceDisposition == .kept)
        let unchanged = try Data(contentsOf: source)
        precondition(unchanged == original)
        try mockedDownload(root: root, fixture: source, tools: tools)
        try realYTDLPDownload(root: root, fixture: source, tools: tools)
        print("Real ffmpeg smoke passed: progress events=\(progressUpdates), verification completed, source unchanged.")
        try SourceCleanupTests.smoke(source: source, encoded: encoded.file, tools: tools, root: root)
    }

    private static func realYTDLPDownload(root: URL, fixture: URL, tools: ToolPaths) throws {
        let directory = root.appendingPathComponent("local-download")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let output = directory.appendingPathComponent("downloaded.mp4")
        let receipt = directory.appendingPathComponent("filepath.jsonl")
        var parser = DownloadProgressParser(streamCount: 1)
        var updates = 0
        try ProcessRunner().stream(executable: tools.ytDLP, arguments: [
            "--ignore-config", "--enable-file-urls", "--no-overwrites", "--no-simulate", "--newline", "--progress",
            "--progress-template", YTDLPService.progressTemplate,
            "--print-to-file", "after_move:%(filepath)j", receipt.path,
            "-o", output.path, fixture.absoluteString,
        ]) { line in
            if line.hasPrefix("KPDL|") {
                let update = parser.parse(line)
                precondition(update.detail.contains("Скачано"))
                updates += 1
            }
        }
        let path = try JSONDecoder().decode(String.self, from: Data(contentsOf: receipt))
        let original = try Data(contentsOf: fixture)
        let copied = try Data(contentsOf: output)
        precondition(path == output.path && updates > 0)
        precondition(original == copied)
        precondition(parser.completedBytes == Double(copied.count))
        print("Real yt-dlp local download passed: progress events=\(updates), \(copied.count) bytes, exact after_move filepath.")
    }

    private static func mockedDownload(root: URL, fixture: URL, tools: ToolPaths) throws {
        let ready = root.appendingPathComponent("ready.mp4")
        try FileManager.default.copyItem(at: fixture, to: ready)
        try Data([0]).write(to: root.appendingPathComponent("ready.mp4.part"))
        let stub = root.appendingPathComponent("mock-ytdlp.sh")
        let jsonPath = String(decoding: try JSONEncoder().encode(ready.path), as: UTF8.self)
        let literal = "'" + jsonPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = """
        #!/bin/sh
        set -eu
        receipt=''
        while [ "$#" -gt 0 ]; do
            if [ "$1" = '--print-to-file' ]; then
                shift
                shift
                receipt="$1"
            fi
            shift
        done
        printf '%s\\n' 'KPDL|combined|1000|2000|NA|100|10|downloading|1'
        printf '%s\\n' 'KPDL|combined|2000|2000|NA|100|0|finished|2' >&2
        printf '%s\\n' \(literal) > "$receipt"
        """
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
        let mockTools = ToolPaths(ytDLP: stub, ffmpeg: tools.ffmpeg, ffprobe: tools.ffprobe, pluginDirectory: nil, uv: nil)
        let service = YTDLPService(tools: mockTools)
        let video = MediaFormat(formatID: "combined", ext: "mp4", formatNote: nil, language: nil, width: 128, height: 72, vcodec: "h264", acodec: "aac", tbr: nil)
        let episode = Episode(id: "smoke", title: "ready", url: "https://example.invalid", series: nil, seasonNumber: nil, episodeNumber: nil, formats: [video])
        var fractions: [Double] = []
        let downloaded = try service.download(episode: episode, video: video, audioIDs: [], destination: root) { update in
            if let fraction = update.fraction { fractions.append(fraction) }
        }
        precondition(downloaded == ready.standardizedFileURL)
        precondition(fractions == [0.5, 1])
        print("Download pipeline mock passed: byte progress, exact final file, no partial file selection.")
    }
}

private final class CancellationPageProtocol: URLProtocol {
    static var onStart: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "vlc-test.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.onStart?()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let html = #"<p>VLC for iOS</p><input id="fileupload" type="file" name="files[]" data-url="upload.json"/>"#
        client?.urlProtocol(self, didLoad: Data(html.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
