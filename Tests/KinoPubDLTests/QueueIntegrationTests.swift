import Foundation

@main
@MainActor
struct QueueIntegrationTests {
    static func wait(_ condition: @MainActor () -> Bool, _ message: String) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw MediaError.commandFailed("Timed out: \(message)")
    }

    static func main() async throws {
        struct Item: Identifiable { let id: Int }
        var state = SerialJobQueue<Item>()
        state.append([Item(id: 1), Item(id: 2)])
        precondition(state.startNext()?.id == 1)
        state.append([Item(id: 3)])
        precondition(state.startNext() == nil)
        state.finish(id: 999)
        precondition(state.active?.id == 1)
        state.removePending(id: 2)
        state.finish(id: 1)
        precondition(state.startNext()?.id == 3)
        state.append([Item(id: 4)])
        state.clearPending()
        precondition(state.active?.id == 3 && state.pending.isEmpty)
        state.finish(id: 3)
        precondition(state.startNext() == nil)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KinoPubQueueTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        var testModel: DownloaderModel?
        defer {
            testModel?.clearPending()
            testModel?.cancel()
            try? FileManager.default.removeItem(at: root)
        }
        let output = root.appendingPathComponent("ready.mp4")
        try Data([1, 2, 3]).write(to: output)
        let release = root.appendingPathComponent("release")
        let stub = root.appendingPathComponent("mock-ytdlp")
        let info = #"{"id":"B","title":"Movie B","webpage_url":"https://kino.watch/item/view/2/s0e1","formats":[{"format_id":"combined","ext":"mp4","vcodec":"h264","acodec":"aac"}]}"#
        let pathJSON = String(decoding: try JSONEncoder().encode(output.path), as: UTF8.self)
        let script = """
        #!/bin/sh
        set -eu
        printf '%s\\n' "$*" >> '\(root.appendingPathComponent("calls.txt").path)'
        case " $* " in
          *'/999/'*) printf 'Simulated failed job\\n' >&2; exit 1;;
          *--dump-single-json*) printf '%s\\n' '\(info)'; exit 0;;
          *' --print '*) printf 'B\\n'; exit 0;;
        esac
        receipt=''
        while [ "$#" -gt 0 ]; do
            if [ "$1" = '--print-to-file' ]; then shift; shift; receipt="$1"; fi
            shift
        done
        printf '%s\\n' 'KPDL|combined|1|3|NA|1|2|downloading|1'
        attempts=0
        while [ ! -e '\(release.path)' ]; do
            attempts=$((attempts + 1))
            [ "$attempts" -lt 300 ] || exit 1
            /bin/sleep 0.1
        done
        printf '%s\\n' 'KPDL|combined|3|3|NA|1|0|finished|3'
        printf '%s\\n' '\(pathJSON)' > "$receipt"
        """
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
        let tools = ToolPaths(ytDLP: stub, ffmpeg: URL(fileURLWithPath: "/usr/bin/false"), ffprobe: URL(fileURLWithPath: "/usr/bin/false"), pluginDirectory: nil, uv: nil)
        let model = DownloaderModel(tools: tools)
        testModel = model
        let video = MediaFormat(formatID: "combined", ext: "mp4", formatNote: nil, language: nil, width: 1280, height: 640, vcodec: "h264", acodec: "aac", tbr: nil)
        let first = Episode(id: "A", title: "Movie A", url: "https://kino.watch/item/view/1/s0e1", series: nil, seasonNumber: nil, episodeNumber: nil, formats: [video])
        model.destination = root
        model.episodes = [first]
        model.selectedEpisodeIDs = [first.id]
        model.formats = [video]
        model.selectedVideoID = video.id
        model.download()
        try await wait({ model.stage == .downloading && model.progressIsKnown }, "A download progress")
        let active = model.queue.active!.id
        let fraction = model.progress
        model.urlText = "https://kino.watch/item/view/2/s0e1"
        model.cookieBrowser = .firefox
        model.checkBrowserCookies()
        try await wait({ !model.isLookingUp }, "browser authorization while A runs")
        precondition(model.authorizationStatus.contains("Доступ подтверждён через Firefox"))
        precondition(model.queue.active?.id == active && model.progress == fraction)
        model.lookup()
        try await wait({ !model.isLookingUp }, "lookup B while A runs")
        precondition(model.title == "Movie B" && model.isBusy)
        precondition(model.queue.active?.id == active && model.progress == fraction)
        model.loadFormats()
        try await wait({ !model.isLookingUp }, "formats while A runs")
        model.download()
        precondition(model.queue.pending.count == 1)
        if case .download(let activeOptions) = model.queue.active!.payload {
            precondition(activeOptions.episode.id == "A" && !activeOptions.encode && activeOptions.cookieBrowser == .safari)
        } else { preconditionFailure("Wrong active job") }
        let b = model.queue.pending[0]
        model.cookieBrowser = .chrome
        model.transcodeToHEVC = true
        model.deleteOriginalAfterEncoding = true
        model.destination = root.appendingPathComponent("changed")
        if case .download(let snapshot) = b.payload {
            precondition(!snapshot.encode && !snapshot.deleteOriginal && snapshot.destination == root && snapshot.cookieBrowser == .firefox)
        } else { preconditionFailure("Wrong queued job") }
        model.localFiles = try LocalTransferFile.selected([output])
        model.vlcAddress = "http://vlc-test.invalid/"
        model.sendLocalFiles()
        precondition(model.queue.pending.count == 2 && model.localFiles.isEmpty)
        model.removePending(model.queue.pending.last!.id)
        precondition(model.queue.pending.count == 1)
        try Data().write(to: release)
        try await wait({ !model.isBusy }, "A then B completed")
        precondition(model.queue.pending.isEmpty && model.queue.active == nil)
        precondition(model.logLines.contains { $0.contains("Movie A: Задача завершена") })
        precondition(model.logLines.contains { $0.contains("Movie B: Задача завершена") })
        precondition(model.errorMessage == nil)
        let calls = try String(contentsOf: root.appendingPathComponent("calls.txt"), encoding: .utf8)
        precondition(calls.contains("--cookies-from-browser safari") && calls.contains("--cookies-from-browser firefox"))

        // Cancellation must not cancel the independent lookup runner or lose waiting jobs.
        try FileManager.default.removeItem(at: release)
        model.destination = root
        model.transcodeToHEVC = false
        model.deleteOriginalAfterEncoding = false
        model.sendToVLC = false
        model.download()
        try await wait({ model.stage == .downloading && model.progressIsKnown }, "new active task")
        model.download()
        precondition(model.queue.pending.count == 1)
        model.cancel()
        try Data().write(to: release)
        try await wait({ !model.isBusy }, "cancel then waiting task")
        precondition(model.queue.pending.isEmpty)
        precondition(model.logLines.contains { $0.contains("Текущая задача отменена") })
        try FileManager.default.removeItem(at: release)
        model.download()
        try await wait({ model.stage == .downloading && model.progressIsKnown }, "active task before failure tests")
        let activeBeforeError = model.queue.active!.id
        model.urlText = "https://kino.watch/item/view/999/failure"
        model.lookup()
        try await wait({ !model.isLookingUp }, "failed lookup")
        precondition(model.errorMessage != nil && model.isBusy && model.queue.active?.id == activeBeforeError)
        model.errorMessage = nil
        let bad = Episode(id: "bad", title: "Broken job", url: "https://kino.watch/item/view/999/failure", series: nil, seasonNumber: nil, episodeNumber: nil, formats: [video])
        model.episodes = [bad]
        model.selectedEpisodeIDs = [bad.id]
        model.download()
        model.episodes = [first]
        model.selectedEpisodeIDs = [first.id]
        model.download()
        precondition(model.queue.pending.count == 2)
        try Data().write(to: release)
        try await wait({ !model.isBusy }, "queue continues after failed job")
        precondition(model.queue.pending.isEmpty)
        precondition(model.logLines.contains { $0.contains("Broken job:") && $0.contains("кодом 1") })
        precondition(model.stage == .completed)
        print("Queue integration passed: append while active, independent lookup/formats, immutable settings, local files, remove pending, FIFO, cancellation, lookup failure and job failure isolation.")
    }
}
