import Foundation

enum WorkflowStage: String {
    case idle, preparing, downloading, merging, encoding, verifying, uploading, completed, cancelled, failed

    var title: String {
        switch self {
        case .idle: return "Готов к работе"
        case .preparing: return "Подготовка"
        case .downloading: return "Скачивание"
        case .merging: return "Объединение видео и звука"
        case .encoding: return "Перекодирование в H.265"
        case .verifying: return "Проверка готового файла"
        case .uploading: return "Передача в VLC"
        case .completed: return "Готово"
        case .cancelled: return "Отменено"
        case .failed: return "Операция остановлена"
        }
    }
}

enum ProgressText {
    static func bytes(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, value)), countStyle: .file)
    }

    static func time(_ seconds: Double) -> String {
        let seconds = Int(max(0, seconds))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct DownloadProgress {
    let stage: WorkflowStage
    let fraction: Double?
    let detail: String
    let logMessage: String?
}

struct DownloadProgressParser {
    let streamCount: Int
    private(set) var completedStreams = 0
    private(set) var completedBytes: Double = 0

    mutating func parse(_ line: String) -> DownloadProgress {
        if line.hasPrefix("[Merger]") || line.hasPrefix("[VideoRemuxer]") || line.hasPrefix("[Fixup") {
            return DownloadProgress(stage: .merging, fraction: nil, detail: "Потоки получены, собираю файл без перекодирования…", logMessage: line)
        }
        guard line.hasPrefix("KPDL|") else {
            return DownloadProgress(stage: .downloading, fraction: nil, detail: "", logMessage: line)
        }
        let parts = line.components(separatedBy: "|")
        guard parts.count >= 9 else {
            return DownloadProgress(stage: .downloading, fraction: nil, detail: "Получаю данные…", logMessage: nil)
        }
        let currentBytes = Self.number(parts[2]) ?? 0
        let total = Self.number(parts[3]) ?? Self.number(parts[4])
        let approximate = Self.number(parts[3]) == nil && total != nil
        let speed = Self.number(parts[5])
        let eta = Self.number(parts[6])
        let finished = parts[7] == "finished"
        let count = max(1, streamCount)
        let currentFraction = finished ? 1 : total.flatMap { $0 > 0 ? min(1, currentBytes / $0) : nil }
        let fraction = currentFraction.map { min(1, (Double(completedStreams) + $0) / Double(count)) }
        var detail = "Скачано \(ProgressText.bytes(completedBytes + currentBytes))"
        if let total {
            detail += " · поток \(min(count, completedStreams + 1))/\(count): \(ProgressText.bytes(currentBytes)) из \(approximate ? "≈" : "")\(ProgressText.bytes(total))"
        } else {
            detail += " · общий объём пока неизвестен"
        }
        if let speed, speed > 0 { detail += " · \(ProgressText.bytes(speed))/с" }
        if let eta { detail += " · осталось ≈\(ProgressText.time(eta)) в потоке" }
        if finished {
            completedBytes += currentBytes
            completedStreams += 1
        }
        return DownloadProgress(stage: .downloading, fraction: fraction, detail: detail, logMessage: nil)
    }

    private static func number(_ text: String) -> Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespaces)), value.isFinite, value >= 0 else { return nil }
        return value
    }
}

struct EncodingProgress {
    let fraction: Double
    let detail: String
}

struct EncodingProgressParser {
    let duration: Double
    private var processed: Double = 0
    private var outputBytes: Double = 0
    private var speed: Double?

    init(duration: Double) { self.duration = duration }

    mutating func parse(_ line: String) -> EncodingProgress? {
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let key = String(parts[0])
        let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
        switch key {
        case "out_time_us":
            if let number = Double(value), number.isFinite { processed = max(0, number / 1_000_000) }
        case "total_size":
            if let number = Double(value), number.isFinite { outputBytes = max(0, number) }
        case "speed":
            speed = Double(value.replacingOccurrences(of: "x", with: "")).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        case "progress":
            let fraction = duration > 0 ? min(0.999, processed / duration) : 0
            var detail = "Обработано \(ProgressText.time(processed)) из \(ProgressText.time(duration))"
            detail += " · новая копия \(ProgressText.bytes(outputBytes))"
            if let speed {
                detail += String(format: " · %.1f×", speed)
                detail += " · осталось ≈\(ProgressText.time(max(0, duration - processed) / speed))"
            }
            return EncodingProgress(fraction: fraction, detail: detail)
        default: break
        }
        return nil
    }
}
