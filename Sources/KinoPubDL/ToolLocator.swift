import Foundation

struct ToolPaths: Sendable {
    let ytDLP: URL
    let ffmpeg: URL
    let ffprobe: URL
    let pluginDirectory: URL?
    let uv: URL?

    static var defaultPluginDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/yt-dlp/plugins/yt-dlp-kinopub", isDirectory: true)
    }
}

enum ToolLocator {
    static var uvExecutable: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return firstExecutable([home.appendingPathComponent(".local/bin/uv"), URL(fileURLWithPath: "/opt/homebrew/bin/uv"), URL(fileURLWithPath: "/usr/local/bin/uv")])
    }

    static func locate() -> ToolPaths? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let ytCandidates = [
            home.appendingPathComponent(".local/bin/yt-dlp"),
            URL(fileURLWithPath: "/opt/homebrew/bin/yt-dlp"),
            URL(fileURLWithPath: "/usr/local/bin/yt-dlp"),
        ]
        let ffmpegCandidates = [URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"), URL(fileURLWithPath: "/usr/local/bin/ffmpeg")]
        let ffprobeCandidates = [URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe"), URL(fileURLWithPath: "/usr/local/bin/ffprobe")]
        guard let ytdlp = firstExecutable(ytCandidates),
              let ffmpeg = firstExecutable(ffmpegCandidates),
              let ffprobe = firstExecutable(ffprobeCandidates)
        else { return nil }
        let plugin = ToolPaths.defaultPluginDirectory
        let pluginSource = plugin.appendingPathComponent("yt_dlp_plugins/extractor/kinopub.py").path
        let pluginDirectory = FileManager.default.fileExists(atPath: pluginSource) ? plugin : nil
        return ToolPaths(ytDLP: ytdlp, ffmpeg: ffmpeg, ffprobe: ffprobe, pluginDirectory: pluginDirectory, uv: uvExecutable)
    }

    private static func firstExecutable(_ urls: [URL]) -> URL? {
        urls.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
