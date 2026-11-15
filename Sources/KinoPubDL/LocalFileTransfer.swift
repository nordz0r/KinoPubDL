import Foundation

struct LocalTransferFile: Identifiable, Equatable {
    let url: URL
    let size: Int64
    var id: URL { url }
    var name: String { url.lastPathComponent }

    static func selected(_ urls: [URL]) throws -> [LocalTransferFile] {
        guard !urls.isEmpty else { throw MediaError.commandFailed("Выберите хотя бы один файл на Mac.") }
        var result: [LocalTransferFile] = []
        for url in urls {
            guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else {
                throw MediaError.commandFailed("Файл недоступен для чтения: \(url.lastPathComponent)")
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
                throw MediaError.commandFailed("Выберите непустой обычный файл, а не папку: \(url.lastPathComponent)")
            }
            if !result.contains(where: { $0.url == url }) {
                result.append(LocalTransferFile(url: url, size: Int64(size)))
            }
        }
        return result
    }
}

struct LocalTransferResult {
    let uploaded: Int
    let manual: Int
}

enum LocalFileTransfer {
    typealias Transfer = (URL, URL, ProcessRunner) throws -> VLCUploadResult

    static func send(
        files: [LocalTransferFile], sharingURL: URL, runner: ProcessRunner,
        transfer: Transfer = { file, url, runner in try VLCUploader.transfer(file: file, sharingURL: url, runner: runner) },
        onFile: (Int, LocalTransferFile) -> Void,
        onManual: (URL, String) -> Void
    ) throws -> LocalTransferResult {
        let current = try LocalTransferFile.selected(files.map(\.url))
        var uploaded = 0
        var manual = 0
        for (index, file) in current.enumerated() {
            try runner.checkCancellation()
            onFile(index, file)
            switch try transfer(file.url, sharingURL, runner) {
            case .uploaded: uploaded += 1
            case .manual(let url, let reason):
                manual += 1
                onManual(url, reason)
            }
            try runner.checkCancellation()
        }
        return LocalTransferResult(uploaded: uploaded, manual: manual)
    }
}
