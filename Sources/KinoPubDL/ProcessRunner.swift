import Foundation

final class ProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var activeProcess: Process?
    private var isCancelled = false

    func resetCancellation() {
        lock.lock()
        isCancelled = false
        lock.unlock()
    }

    func checkCancellation() throws {
        lock.lock()
        let cancelled = isCancelled
        lock.unlock()
        if cancelled { throw CancellationError() }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let process = activeProcess
        lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }

    func capture(executable: URL, arguments: [String]) throws -> Data {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        try start(process)

        let stdoutBox = DataBox()
        let stderrBox = DataBox()
        let stdoutDone = DispatchSemaphore(value: 0)
        let stderrDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            stdoutBox.set(stdout.fileHandleForReading.readDataToEndOfFile())
            stdoutDone.signal()
        }
        DispatchQueue.global(qos: .utility).async {
            stderrBox.set(stderr.fileHandleForReading.readDataToEndOfFile())
            stderrDone.signal()
        }
        process.waitUntilExit()
        stdoutDone.wait()
        stderrDone.wait()
        clearActive(process)
        try checkCancellation()

        guard process.terminationStatus == 0 else {
            let detail = String(decoding: stderrBox.get(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = detail.isEmpty ? "" : "\n\(String(detail.suffix(1200)))"
            throw MediaError.commandFailed("Команда завершилась с кодом \(process.terminationStatus). Проверьте доступ к Safari, ссылку и авторизацию.\(suffix)")
        }
        return stdoutBox.get()
    }

    func stream(executable: URL, arguments: [String], onLine: @escaping (String) -> Void) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try start(process)

        let reader = output.fileHandleForReading
        var pending = Data()
        var lastLines: [String] = []
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            while let newline = pending.firstRange(of: Data([0x0A])) {
                let lineData = pending.subdata(in: pending.startIndex..<newline.lowerBound)
                pending.removeSubrange(pending.startIndex..<newline.upperBound)
                let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty {
                    lastLines.append(line)
                    if lastLines.count > 12 { lastLines.removeFirst() }
                    onLine(line)
                }
            }
        }
        if !pending.isEmpty {
            onLine(String(decoding: pending, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        process.waitUntilExit()
        clearActive(process)
        try checkCancellation()
        guard process.terminationStatus == 0 else {
            let detail = lastLines.joined(separator: "\n")
            throw MediaError.commandFailed("\(executable.lastPathComponent) завершился с кодом \(process.terminationStatus).\n\(detail)")
        }
    }

    private func start(_ process: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        if isCancelled { throw CancellationError() }
        try process.run()
        activeProcess = process
    }

    private func clearActive(_ process: Process) {
        lock.lock()
        if activeProcess === process { activeProcess = nil }
        lock.unlock()
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()

    func set(_ data: Data) {
        lock.lock()
        value = data
        lock.unlock()
    }

    func get() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
