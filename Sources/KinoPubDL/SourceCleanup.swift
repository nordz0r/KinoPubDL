import Foundation

enum SourceDisposition: Equatable {
    case kept
    case trashed
    case warning(String)

    var message: String {
        switch self {
        case .kept: return "Оригинал сохранён."
        case .trashed: return "Исходник перемещён в Корзину."
        case .warning(let text): return text
        }
    }
}

struct SourceFileSnapshot: Equatable {
    let device: UInt64
    let inode: UInt64
    let size: UInt64
    let modified: Date

    static func read(_ file: URL) throws -> SourceFileSnapshot {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard file.isFileURL, attributes[.type] as? FileAttributeType == .typeRegular,
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let size = attributes[.size] as? NSNumber, size.uint64Value > 0,
              let modified = attributes[.modificationDate] as? Date else {
            throw MediaError.commandFailed("Не удалось безопасно проверить исходный файл перед удалением.")
        }
        return SourceFileSnapshot(device: device.uint64Value, inode: inode.uint64Value, size: size.uint64Value, modified: modified)
    }
}

enum SourceCleanup {
    static func moveToTrash(_ file: URL) throws {
        try FileManager.default.trashItem(at: file, resultingItemURL: nil)
    }

    static func finish(
        source: URL,
        verifiedCopy: URL,
        expectedSource: SourceFileSnapshot,
        runner: ProcessRunner,
        trash: (URL) throws -> Void = SourceCleanup.moveToTrash
    ) throws -> SourceDisposition {
        try runner.checkCancellation()
        do {
            let current = try SourceFileSnapshot.read(source)
            let copy = try SourceFileSnapshot.read(verifiedCopy)
            guard current == expectedSource else {
                return .warning("Исходник изменился во время обработки — удаление пропущено.")
            }
            guard source.standardizedFileURL.resolvingSymlinksInPath() != verifiedCopy.standardizedFileURL.resolvingSymlinksInPath(),
                  current.device != copy.device || current.inode != copy.inode else {
                return .warning("Исходник и готовая копия совпадают — удаление пропущено.")
            }
            try runner.checkCancellation()
            try trash(source)
            return .trashed
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .warning("Готовая копия сохранена, но перемещение исходника в Корзину не удалось: \(error.localizedDescription)")
        }
    }
}
