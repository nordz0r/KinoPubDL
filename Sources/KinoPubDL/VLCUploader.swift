import Foundation
import AppKit

struct VLCUploadForm: Equatable, Sendable {
    let action: URL
    let fileField: String
    let hiddenFields: [String: String]
}

enum VLCUploadResult: Sendable {
    case uploaded
    case manual(URL, String)
}

enum VLCUploader {
    static func sharingURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let address = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard let components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        return components.url
    }

    static func isVLCSharingPage(_ html: String) -> Bool {
        let lower = html.lowercased()
        return lower.contains("vlc for ios") && lower.contains("fileupload") && lower.contains("files[]")
    }

    private static func sameOrigin(_ action: URL, _ page: URL) -> Bool {
        guard let scheme = action.scheme?.lowercased(), ["http", "https"].contains(scheme),
              action.user == nil, action.password == nil else { return false }
        return scheme == page.scheme?.lowercased()
            && action.host?.lowercased() == page.host?.lowercased()
            && (action.port ?? (scheme == "https" ? 443 : 80)) == (page.port ?? (scheme == "https" ? 443 : 80))
    }

    static func uploadForm(in html: String, pageURL: URL) -> VLCUploadForm? {
        guard let formRegex = try? NSRegularExpression(pattern: #"(?is)<form\b([^>]*)>(.*?)</form>"#) else { return nil }
        let ns = html as NSString
        let range = NSRange(location: 0, length: ns.length)
        for match in formRegex.matches(in: html, range: range) {
            let formAttributes = ns.substring(with: match.range(at: 1))
            let body = ns.substring(with: match.range(at: 2))
            let attrs = parseAttributes(formAttributes)
            guard (attrs["method"] ?? "get").lowercased() == "post",
                  (attrs["enctype"] ?? "").lowercased().contains("multipart/form-data") else { continue }
            guard let fileInput = inputElements(in: body).first(where: { $0["type"]?.lowercased() == "file" }),
                  let field = fileInput["name"] else { continue }
            let action = URL(string: attrs["action"] ?? "", relativeTo: pageURL)?.absoluteURL ?? pageURL
            guard sameOrigin(action, pageURL) else { continue }
            let hidden = inputElements(in: body).reduce(into: [String: String]()) { result, input in
                if input["type"]?.lowercased() == "hidden", let name = input["name"] {
                    result[name] = input["value"] ?? ""
                }
            }
            return VLCUploadForm(action: action, fileField: field, hiddenFields: hidden)
        }
        if isVLCSharingPage(html),
           let input = inputElements(in: html).first(where: {
               $0["type"]?.lowercased() == "file" && $0["data-url"] != nil
           }), let path = input["data-url"], let field = input["name"],
           let action = URL(string: path, relativeTo: pageURL)?.absoluteURL,
           sameOrigin(action, pageURL) {
            return VLCUploadForm(action: action, fileField: field, hiddenFields: [:])
        }
        return nil
    }

    static func transfer(file: URL, sharingURL: URL, runner: ProcessRunner = ProcessRunner(), session: URLSession = .shared) throws -> VLCUploadResult {
        try runner.checkCancellation()
        var request = URLRequest(url: sharingURL)
        request.timeoutInterval = 15
        let semaphore = DispatchSemaphore(value: 0)
        var pageData: Data?
        var responseError: Error?
        let task = session.dataTask(with: request) { data, _, error in
            pageData = data
            responseError = error
            semaphore.signal()
        }
        task.resume()
        while semaphore.wait(timeout: .now() + 0.1) == .timedOut {
            do { try runner.checkCancellation() }
            catch { task.cancel(); throw error }
        }
        try runner.checkCancellation()
        if let responseError { throw responseError }
        guard let pageData, let html = String(data: pageData, encoding: .utf8) else {
            return .manual(sharingURL, "Не удалось прочитать страницу VLC.")
        }
        guard let form = uploadForm(in: html, pageURL: sharingURL) else {
            return .manual(sharingURL, "Страница VLC не предоставляет стандартную форму загрузки. Откройте её и добавьте файл вручную.")
        }
        try runner.checkCancellation()
        return try curlUpload(file: file, form: form, runner: runner)
    }

    private static func curlUpload(file: URL, form: VLCUploadForm, runner: ProcessRunner) throws -> VLCUploadResult {
        try runner.checkCancellation()
        let curl = URL(fileURLWithPath: "/usr/bin/curl")
        guard FileManager.default.isExecutableFile(atPath: curl.path) else {
            return .manual(form.action, "curl не найден; добавьте файл на странице VLC вручную.")
        }
        var args = ["--fail", "--silent", "--show-error", "--max-time", "3600"]
        for (name, value) in form.hiddenFields.sorted(by: { $0.key < $1.key }) {
            args += ["--form-string", "\(name)=\(value)"]
        }
        let path = file.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        args += ["-F", "\(form.fileField)=@\"\(path)\"", form.action.absoluteString]
        do {
            _ = try runner.capture(executable: curl, arguments: args)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .manual(form.action, "VLC отклонил автоматическую передачу: \(error.localizedDescription). Добавьте файл на странице вручную.")
        }
        return .uploaded
    }

    private static func inputElements(in html: String) -> [[String: String]] {
        guard let regex = try? NSRegularExpression(pattern: #"(?is)<input\b([^>]*)>"#) else { return [] }
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).map {
            parseAttributes(ns.substring(with: $0.range(at: 1)))
        }
    }

    private static func parseAttributes(_ source: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: #"([\w:-]+)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))"#) else { return [:] }
        let ns = source as NSString
        return regex.matches(in: source, range: NSRange(location: 0, length: ns.length)).reduce(into: [:]) { result, match in
            guard match.numberOfRanges > 1 else { return }
            let key = ns.substring(with: match.range(at: 1)).lowercased()
            let valueRange = [2, 3, 4].map { match.range(at: $0) }.first(where: { $0.location != NSNotFound })
            if let valueRange { result[key] = ns.substring(with: valueRange) }
        }
    }
}
