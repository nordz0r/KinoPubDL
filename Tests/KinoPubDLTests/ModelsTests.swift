import Foundation

@main
struct ModelsSmokeTests {
    static func main() throws {
        if CommandLine.arguments.contains("--pipeline-smoke") {
            try PipelineTests.run()
            try PipelineTests.smoke()
            return
        }
        if CommandLine.arguments.contains("--media-json") {
            let info = try JSONDecoder().decode(YDLInfo.self, from: FileHandle.standardInput.readDataToEndOfFile())
            let formats = info.formats ?? []
            let audio = formats.filter(\.isAudioOnly)
            let video = formats.filter(\.hasVideo)
            guard let firstVideo = video.first,
                  let track = audio.first(where: { $0.qualityRung == firstVideo.qualityRung }) else {
                throw MediaError.commandFailed("No matching source video/audio formats")
            }
            let selection = try FormatSelector.make(video: firstVideo, audioIDs: [track.formatID])
            print("Actual metadata verified: video=\(video.count), audio=\(audio.count), selector=\(selection.selector)")
            return
        }
        if CommandLine.arguments.contains("--discover") {
            let discovery = VLCDiscovery()
            discovery.onDevice = { device in print("VLC discovered: \(device.name) \(device.url.absoluteString)") }
            discovery.search()
            RunLoop.main.run(until: Date().addingTimeInterval(11))
            print(discovery.status)
            guard !discovery.devices.isEmpty else { throw MediaError.commandFailed("No VLC found via Bonjour") }
            return
        }
        if CommandLine.arguments.contains("--vlc-page"), let address = CommandLine.arguments.last,
           let url = URL(string: address) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = ["--fail", "--silent", "--show-error", "--max-time", "5", url.absoluteString]
            process.standardOutput = pipe
            try process.run()
            let html = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw MediaError.commandFailed("VLC page unavailable") }
            guard let form = VLCUploader.uploadForm(in: html, pageURL: url) else {
                throw MediaError.commandFailed("No upload form in actual VLC page")
            }
            print("VLC page verified: endpoint=\(form.action.absoluteString), fileField=\(form.fileField)")
            return
        }
        try browserCookieArgumentsAndAddressValidation()
        try decodeAndIdentifyAvailableH265()
        try buildAudioSelectors()
        safeEpisodePath()
        try mapPlaylistEpisodes()
        detectVLCUploadForm()
        try unknownAudioCodec()
        try muxedAudioDoesNotNeedSeparateTrack()
        detectActualVLCMarkup()
        let neighbors = VLCDiscovery.neighborAddresses(in: "? (192.168.30.22) at aa on en0\n? (224.0.0.251) at bb on en0\n? (192.168.30.4) at cc on en0 permanent\n? (8.8.8.8) at dd on en0")
        precondition(neighbors == ["192.168.30.22"])
        print("Model and VLC upload-form smoke tests passed (9 groups).")
        try PipelineTests.run()
    }

    private static func browserCookieArgumentsAndAddressValidation() throws {
        for browser in CookieBrowser.allCases {
            precondition(browser.arguments == ["--cookies-from-browser", browser.rawValue])
            precondition(!browser.title.isEmpty)
        }
        precondition(CookieBrowser.allCases.count == 8)
        let accepted = try KinoPubAddress.validate("https://kino.watch/item/view/128581/s0e1")
        precondition(accepted.contains("128581"))
        for address in ["file:///tmp/cookies", "https://other.invalid/item/view/1", "https://kino.watch.invalid/item/view/1", "https://kino.watch/user/login", "https://user:password@kino.watch/item/view/1"] {
            do { _ = try KinoPubAddress.validate(address); preconditionFailure("Accepted unsupported authorization destination") }
            catch is MediaError {}
        }
        print("Browser cookies tests passed: eight browsers and Kino.Pub-only authorization destinations.")
    }

    private static func decodeAndIdentifyAvailableH265() throws {
        let json = #"{"id":"123","title":"Test","webpage_url":"https://kino.watch/item/view/123/s1e1","formats":[{"format_id":"hls-720p","ext":"mp4","width":1280,"height":534,"vcodec":"avc1.640028","acodec":"none"},{"format_id":"hls-h265-720p","ext":"mp4","width":1280,"height":534,"vcodec":"hev1","acodec":"none"},{"format_id":"audio-720-1","ext":"mp4","format_note":"Дубляж. Studio","language":"rus","vcodec":"none","acodec":"aac"}]}"#
        let info = try JSONDecoder().decode(YDLInfo.self, from: Data(json.utf8))
        let lookup = try MediaLookup.make(from: info, inputURL: "https://kino.watch/item/view/123/s1e1")
        precondition(lookup.episodes.count == 1)
        precondition(lookup.episodes[0].formats[1].codecLabel == "H.265")
        precondition(lookup.episodes[0].formats[2].qualityRung == 720)
    }

    private static func buildAudioSelectors() throws {
        let video = MediaFormat(formatID: "hls-720p", ext: "mp4", formatNote: nil, language: nil, width: 1280, height: 534, vcodec: "avc1", acodec: "none", tbr: nil)
        let one = try FormatSelector.make(video: video, audioIDs: ["audio-720-1"])
        precondition(one.selector == "hls-720p+audio-720-1")
        precondition(!one.multipleAudio)
        let many = try FormatSelector.make(video: video, audioIDs: ["audio-720-2", "audio-720-1"])
        precondition(many.selector == "hls-720p+audio-720-1+audio-720-2")
        precondition(many.multipleAudio)
    }

    private static func safeEpisodePath() {
        let episode = Episode(id: "1", title: "Title/Part: one", url: "https://example.invalid", series: "My/Show", seasonNumber: 1, episodeNumber: 2, formats: [])
        precondition(episode.outputRelativePath == "My-Show/S01E02 - Title-Part- one.%(ext)s")
    }

    private static func mapPlaylistEpisodes() throws {
        let json = #"{"title":"Series","entries":[{"id":"e1","title":"Episode 1","url":"https://kino.watch/item/view/1/s1e1","season_number":1,"episode_number":1},{"id":"e2","title":"Episode 2","url":"https://kino.watch/item/view/1/s1e2","season_number":1,"episode_number":2}]}"#
        let info = try JSONDecoder().decode(YDLInfo.self, from: Data(json.utf8))
        let lookup = try MediaLookup.make(from: info, inputURL: "https://kino.watch/item/view/1")
        precondition(lookup.episodes.map(\.episodeNumber) == [1, 2])
        precondition(lookup.episodes[0].displayName == "S01E01 — Episode 1")
    }

    private static func unknownAudioCodec() throws {
        let json = #"{"format_id":"audio-1080-1","vcodec":"none","acodec":null,"format_note":"Одноголосый. М. Яроцкий","ext":"mp4"}"#
        let track = try JSONDecoder().decode(MediaFormat.self, from: Data(json.utf8))
        precondition(track.isAudioOnly && track.hasAudio && !track.hasVideo)
        precondition(track.qualityRung == 1080)
        let omitted = #"{"format_id":"audio-720-1","vcodec":"none"}"#
        let omittedTrack = try JSONDecoder().decode(MediaFormat.self, from: Data(omitted.utf8))
        precondition(omittedTrack.isAudioOnly)
    }

    private static func muxedAudioDoesNotNeedSeparateTrack() throws {
        let json = #"{"format_id":"combined","vcodec":"avc1","acodec":"aac"}"#
        let format = try JSONDecoder().decode(MediaFormat.self, from: Data(json.utf8))
        let selected = try FormatSelector.make(video: format, audioIDs: [])
        precondition(selected.selector == "combined")
    }

    private static func detectActualVLCMarkup() {
        let base = URL(string: "http://ipad.local:8080/")!
        let html = #"<p>VLC for iOS</p><input id="fileupload" type="file" name="files[]" data-url="upload.json" multiple/>"#
        precondition(VLCUploader.isVLCSharingPage(html))
        let form = VLCUploader.uploadForm(in: html, pageURL: base)
        precondition(form?.action == URL(string: "http://ipad.local:8080/upload.json"))
        precondition(form?.fileField == "files[]")
        let external = html.replacingOccurrences(of: "upload.json", with: "https://other.invalid/upload")
        precondition(VLCUploader.uploadForm(in: external, pageURL: base) == nil)
    }

    private static func detectVLCUploadForm() {
        let page = #"<form method="post" enctype="multipart/form-data" action="/upload"><input type="hidden" name="csrf" value="abc123"><input type="file" name="files[]"></form>"#
        let base = URL(string: "http://ipad.local:8080/")!
        let form = VLCUploader.uploadForm(in: page, pageURL: base)
        precondition(form?.action.absoluteString == "http://ipad.local:8080/upload")
        precondition(form?.fileField == "files[]")
        precondition(form?.hiddenFields["csrf"] == "abc123")
        precondition(VLCUploader.uploadForm(in: "<p>Wi-Fi sharing</p>", pageURL: base) == nil)
    }
}
