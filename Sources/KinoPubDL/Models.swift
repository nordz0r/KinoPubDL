import Foundation

struct MediaFormat: Decodable, Hashable, Identifiable, Sendable {
    let formatID: String
    let ext: String?
    let formatNote: String?
    let language: String?
    let width: Int?
    let height: Int?
    let vcodec: String?
    let acodec: String?
    let tbr: Double?

    var id: String { formatID }
    var hasVideo: Bool { vcodec.map { $0.lowercased() != "none" } ?? false }
    var hasAudio: Bool {
        if let acodec { return acodec.lowercased() != "none" }
        // HLS audio renditions may omit the codec while explicitly marking video as absent.
        return vcodec?.lowercased() == "none"
    }
    var isVideoOnly: Bool { hasVideo && !hasAudio }
    var isAudioOnly: Bool { !hasVideo && hasAudio }

    var codecLabel: String {
        let value = (vcodec ?? "").lowercased()
        if value.contains("hevc") || value.contains("hev1") || value.contains("hvc1") || value.contains("h265") || formatID.lowercased().contains("h265") { return "H.265" }
        if value.contains("avc") || value.contains("h264") || formatID.lowercased().contains("h264") { return "H.264" }
        return hasVideo ? (vcodec ?? "Видео") : "Аудио"
    }

    var qualityRung: Int? {
        let id = formatID.lowercased()
        if let match = id.range(of: #"([0-9]{3,4})p"#, options: .regularExpression) {
            let text = String(id[match]).dropLast()
            return Int(text)
        }
        if isAudioOnly {
            let parts = id.split(separator: "-")
            if parts.count > 1 { return Int(parts[1]) }
        }
        return height
    }

    var displayName: String {
        if isAudioOnly {
            let languageLabel = language.map { "[\($0)] " } ?? ""
            let note = formatNote.map { " — \($0)" } ?? ""
            return "\(languageLabel)\(formatID)\(note)"
        }
        let resolution = width.flatMap { w in height.map { "\(w)×\($0)" } } ?? (height.map { "\($0)p" } ?? "размер не указан")
        let container = ext?.uppercased() ?? "источник"
        let rate = tbr.map { String(format: " · %.0f kb/s", $0) } ?? ""
        return "\(resolution) · \(codecLabel) · \(container)\(rate) · \(formatID)"
    }

    enum CodingKeys: String, CodingKey {
        case formatID = "format_id"
        case ext
        case formatNote = "format_note"
        case language
        case width
        case height
        case vcodec
        case acodec
        case tbr
    }
}

struct YDLInfo: Decodable, Sendable {
    let id: String?
    let title: String?
    let webpageURL: String?
    let url: String?
    let series: String?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let formats: [MediaFormat]?
    let entries: [YDLInfo]?

    enum CodingKeys: String, CodingKey {
        case id, title, url, series, formats, entries
        case webpageURL = "webpage_url"
        case seasonNumber = "season_number"
        case episodeNumber = "episode_number"
    }
}

struct Episode: Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let url: String
    let series: String?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let formats: [MediaFormat]

    var displayName: String {
        if let seasonNumber, let episodeNumber {
            return String(format: "S%02dE%02d — %@", seasonNumber, episodeNumber, title)
        }
        return title
    }

    var outputRelativePath: String {
        let safeTitle = Self.safePathComponent(title)
        guard let seasonNumber, let episodeNumber else { return "\(safeTitle).%(ext)s" }
        let folder = Self.safePathComponent(series ?? "Сериал")
        return "\(folder)/S\(String(format: "%02d", seasonNumber))E\(String(format: "%02d", episodeNumber)) - \(safeTitle).%(ext)s"
    }

    static func safePathComponent(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r")
        let cleaned = value.components(separatedBy: forbidden).filter { !$0.isEmpty }.joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned.allSatisfy({ $0 == "." }) ? "video" : String(cleaned.prefix(160))
    }
}

struct MediaLookup: Sendable {
    let title: String
    let episodes: [Episode]

    static func make(from info: YDLInfo, inputURL: String) throws -> MediaLookup {
        let title = info.title ?? "KinoPub"
        if let entries = info.entries, !entries.isEmpty {
            let episodes = entries.compactMap { entry -> Episode? in
                guard let url = entry.webpageURL ?? entry.url else { return nil }
                return Episode(
                    id: entry.id ?? url,
                    title: entry.title ?? "Без названия",
                    url: url,
                    series: entry.series ?? title,
                    seasonNumber: entry.seasonNumber,
                    episodeNumber: entry.episodeNumber,
                    formats: entry.formats ?? []
                )
            }
            guard !episodes.isEmpty else { throw MediaError.noEpisodes }
            return MediaLookup(title: title, episodes: episodes)
        }

        return MediaLookup(title: title, episodes: [Episode(
            id: info.id ?? inputURL,
            title: info.title ?? inputURL,
            url: info.webpageURL ?? inputURL,
            series: info.series,
            seasonNumber: info.seasonNumber,
            episodeNumber: info.episodeNumber,
            formats: info.formats ?? []
        )])
    }
}

enum MediaError: LocalizedError {
    case noEpisodes
    case noFormats(String)
    case missingFormat(String)
    case invalidURL
    case toolUnavailable(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .noEpisodes:
            return "По ссылке не найдено ни одного видео. Проверьте ссылку и доступ к аккаунту."
        case .noFormats(let title):
            return "Для «\(title)» не найдены форматы. Возможно, нужна активная подписка или другой вариант входа."
        case .missingFormat(let detail):
            return "Выбранная дорожка или качество недоступны: \(detail). Выберите другой вариант."
        case .invalidURL:
            return "Введите корректную ссылку на kino.pub или kino.watch."
        case .toolUnavailable(let name):
            return "Не найден \(name). Установите его и перезапустите приложение."
        case .commandFailed(let message):
            return message
        }
    }
}

enum FormatSelector {
    static func make(video: MediaFormat, audioIDs: Set<String>) throws -> (selector: String, multipleAudio: Bool) {
        guard video.hasVideo else { throw MediaError.missingFormat(video.formatID) }
        if video.hasAudio {
            guard audioIDs.isEmpty else { throw MediaError.missingFormat("аудио уже включено в выбранный поток") }
            return (video.formatID, false)
        }
        guard video.isVideoOnly else { throw MediaError.missingFormat(video.formatID) }
        guard !audioIDs.isEmpty else { throw MediaError.missingFormat("не выбрана аудиодорожка") }
        let sorted = audioIDs.sorted()
        return (([video.formatID] + sorted).joined(separator: "+"), sorted.count > 1)
    }
}
