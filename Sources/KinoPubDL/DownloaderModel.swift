import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class DownloaderModel: ObservableObject {
    @Published var urlText = ""
    @Published var cookieBrowser: CookieBrowser = .safari
    @Published var authorizationStatus = "Войдите в Kino.Pub в браузере, затем проверьте авторизацию по ссылке на фильм или серию."
    @Published var title = ""
    @Published var episodes: [Episode] = []
    @Published var selectedEpisodeIDs = Set<String>()
    @Published var formats: [MediaFormat] = []
    @Published var selectedVideoID = ""
    @Published var selectedAudioIDs = Set<String>()
    @Published var destination = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies", isDirectory: true)
    @Published var sendToVLC = false
    @Published var vlcAddress = ""
    @Published private(set) var isBusy = false
    @Published private(set) var isLookingUp = false
    @Published var lookupStatus = "Вставьте ссылку на фильм или сериал."
    @Published var progress: Double = 0
    @Published var stage: WorkflowStage = .idle
    @Published var progressIsKnown = false
    @Published var progressDetail = ""
    @Published var transcodeToHEVC = false
    @Published var deleteOriginalAfterEncoding = false
    @Published var lastComparison = ""
    @Published var localFiles: [LocalTransferFile] = []
    @Published var status = "Очередь пуста."
    @Published var logLines: [String] = []
    @Published var errorMessage: String?
    @Published private(set) var queue = SerialJobQueue<MediaJob>()

    private var tools: ToolPaths?
    private var lookupService: YTDLPService?
    private var activeRunner: ProcessRunner?

    init(tools: ToolPaths? = ToolLocator.locate()) {
        self.tools = tools
        lookupService = tools.map { YTDLPService(tools: $0) }
    }

    private func configureTools() {
        tools = ToolLocator.locate()
        lookupService = tools.map { YTDLPService(tools: $0) }
    }

    var sharingURL: URL? { VLCUploader.sharingURL(from: vlcAddress) }
    var toolsReady: Bool { tools != nil }
    var canInstallViaUV: Bool { ToolLocator.uvExecutable != nil }
    var selectedEpisodes: [Episode] { episodes.filter { selectedEpisodeIDs.contains($0.id) } }
    var videoFormats: [MediaFormat] { formats.filter(\.hasVideo).sorted { ($0.height ?? 0) > ($1.height ?? 0) } }
    var selectedVideo: MediaFormat? { videoFormats.first { $0.formatID == selectedVideoID } }
    var audioFormats: [MediaFormat] {
        guard selectedVideo?.isVideoOnly == true else { return [] }
        let all = formats.filter(\.isAudioOnly)
        guard let rung = selectedVideo?.qualityRung else { return all }
        let matching = all.filter { $0.qualityRung == rung }
        return matching.isEmpty ? all : matching
    }
    var toolError: String { "Не найдены yt-dlp, ffmpeg, ffprobe или плагин KinoPub. Проверьте /opt/homebrew/bin и ~/.config/yt-dlp/plugins/yt-dlp-kinopub." }

    func installYTDLPViaUV() {
        guard !isLookingUp, !isBusy, let uv = ToolLocator.uvExecutable else { return }
        isLookingUp = true
        lookupStatus = "Устанавливаю yt-dlp и плагин…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                _ = try ProcessRunner().capture(executable: uv, arguments: ["tool", "install", "yt-dlp", "--with", "yt-dlp-kinopub"])
                DispatchQueue.main.async {
                    self?.configureTools()
                    self?.isLookingUp = false
                    self?.lookupStatus = "Установка завершена. Вставьте ссылку."
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isLookingUp = false
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func cookieBrowserChanged() {
        authorizationStatus = "Выбран \(cookieBrowser.title). Cookies будут прочитаны заново; задачи очереди сохраняют свой браузер."
        episodes = []
        formats = []
        selectedEpisodeIDs = []
        selectedVideoID = ""
        selectedAudioIDs = []
        title = ""
    }

    func checkBrowserCookies() {
        guard !isLookingUp else { return }
        guard let tools else { errorMessage = toolError; return }
        let url: String
        do { url = try KinoPubAddress.validate(urlText.trimmingCharacters(in: .whitespacesAndNewlines)) }
        catch { errorMessage = "Сначала вставьте ссылку на фильм или серию Kino.Pub для проверки авторизации."; return }
        let browser = cookieBrowser
        let service = YTDLPService(tools: tools, browser: browser)
        lookupService = service
        isLookingUp = true
        authorizationStatus = "Читаю cookies \(browser.title) и проверяю доступ к указанному видео…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try service.checkAuthorization(url: url)
                DispatchQueue.main.async {
                    self?.isLookingUp = false
                    self?.authorizationStatus = "Доступ подтверждён через \(browser.title). Cookies не сохранялись в отдельный файл."
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isLookingUp = false
                    self?.authorizationStatus = "Не удалось подтвердить доступ через \(browser.title). Войдите на сайт, проверьте подписку и разрешения macOS."
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func lookup() {
        guard !isLookingUp else { return }
        guard let tools else { errorMessage = toolError; return }
        let service = YTDLPService(tools: tools, browser: cookieBrowser)
        lookupService = service
        let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { errorMessage = MediaError.invalidURL.localizedDescription; return }
        service.beginOperation()
        isLookingUp = true
        lookupStatus = "Ищу фильм или серии… Загрузка очереди продолжается."
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let result = try service.lookup(url: url)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.title = result.title
                    self.episodes = result.episodes
                    self.selectedEpisodeIDs = result.episodes.count == 1 ? [result.episodes[0].id] : []
                    self.formats = result.episodes.count == 1 ? result.episodes[0].formats : []
                    self.selectedVideoID = ""
                    self.chooseDefaults()
                    self.isLookingUp = false
                    self.lookupStatus = "Найдено записей: \(result.episodes.count). Выберите нужные и добавьте в очередь."
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isLookingUp = false
                    self?.lookupStatus = "Поиск не выполнен. Текущая очередь не изменена."
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func loadFormats() {
        guard !isLookingUp else { return }
        guard let tools else { errorMessage = toolError; return }
        let service = YTDLPService(tools: tools, browser: cookieBrowser)
        lookupService = service
        guard let episode = selectedEpisodes.first else { errorMessage = "Отметьте серию."; return }
        service.beginOperation()
        isLookingUp = true
        lookupStatus = "Получаю доступные форматы…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let formats = try service.formats(for: episode)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.formats = formats
                    self.chooseDefaults()
                    self.isLookingUp = false
                    self.lookupStatus = "Видео: \(formats.filter(\.hasVideo).count), аудиодорожек: \(formats.filter(\.isAudioOnly).count). Можно добавить в очередь."
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isLookingUp = false
                    self?.lookupStatus = "Не удалось получить форматы. Очередь продолжает работу."
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func download() {
        guard !isLookingUp else { return }
        guard tools != nil else { errorMessage = toolError; return }
        guard !selectedEpisodes.isEmpty, let video = selectedVideo else { errorMessage = "Выберите серии и качество."; return }
        do { _ = try FormatSelector.make(video: video, audioIDs: selectedAudioIDs) }
        catch { errorMessage = error.localizedDescription; return }
        if sendToVLC && sharingURL == nil { errorMessage = "Найдите VLC или введите его адрес."; return }
        let jobs = selectedEpisodes.map { episode in
            MediaJob(title: episode.displayName,
                     detail: "\(video.displayName) · \(cookieBrowser.title) · \(selectedAudioIDs.sorted().joined(separator: ", "))\(transcodeToHEVC ? " · H.265-копия" : "")\(transcodeToHEVC && deleteOriginalAfterEncoding ? " · исходник в Корзину" : "")\(sendToVLC ? " · в VLC" : "")",
                     payload: .download(DownloadJob(episode: episode, video: video, audioIDs: selectedAudioIDs,
                         destination: destination, encode: transcodeToHEVC,
                         deleteOriginal: transcodeToHEVC && deleteOriginalAfterEncoding,
                         sharingURL: sendToVLC ? sharingURL : nil, cookieBrowser: cookieBrowser)))
        }
        queue.append(jobs)
        lookupStatus = "Добавлено задач: \(jobs.count). Можно вставить следующую ссылку."
        startNext()
    }

    private func startNext() {
        guard let job = queue.startNext() else { return }
        isBusy = true
        lastComparison = ""
        status = job.title
        setStage(.preparing, detail: "Подготавливаю задачу…")
        let runner = ProcessRunner()
        activeRunner = runner
        let jobBrowser: CookieBrowser
        if case .download(let options) = job.payload { jobBrowser = options.cookieBrowser } else { jobBrowser = .safari }
        let service = tools.map { YTDLPService(tools: $0, runner: runner, browser: jobBrowser) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                var completion = "Задача завершена."
                switch job.payload {
                case .download(let options):
                    guard let service else { throw MediaError.toolUnavailable("yt-dlp/ffmpeg") }
                    let available = try service.formats(for: options.episode)
                    guard let video = available.first(where: { $0.formatID == options.video.formatID }),
                          options.audioIDs.allSatisfy({ id in available.contains { $0.formatID == id && $0.isAudioOnly } }) else {
                        throw MediaError.missingFormat(options.episode.displayName)
                    }
                    var file = try service.download(episode: options.episode, video: video, audioIDs: options.audioIDs, destination: options.destination) { update in
                        DispatchQueue.main.async {
                            guard let self, self.queue.active?.id == job.id else { return }
                            if !update.detail.isEmpty { self.setStage(update.stage, fraction: update.fraction, detail: update.detail) }
                            if let message = update.logMessage { self.appendLog(message) }
                        }
                    }
                    if options.encode {
                        DispatchQueue.main.async { self?.setStage(.encoding, detail: "Создаю H.265-копию…") }
                        let result = try service.transcode(file: file, deleteOriginalAfterSuccess: options.deleteOriginal, onProgress: { update in
                            DispatchQueue.main.async { self?.setStage(.encoding, fraction: update.fraction, detail: update.detail) }
                        }, onVerifying: {
                            DispatchQueue.main.async { self?.setStage(.verifying, detail: "Проверяю готовую копию перед дальнейшими действиями…") }
                        })
                        file = result.file
                        DispatchQueue.main.async {
                            self?.lastComparison = result.summary
                            self?.appendLog(result.summary)
                        }
                    }
                    try runner.checkCancellation()
                    if let target = options.sharingURL {
                        DispatchQueue.main.async { self?.setStage(.uploading, detail: "Передаю \(file.lastPathComponent) в VLC…") }
                        completion = try Self.transferMessage(file: file, target: target, runner: runner, onManual: { url, message in
                            DispatchQueue.main.async { NSWorkspace.shared.open(url); self?.appendLog(message) }
                        })
                    }
                case .transfer(let file, let target):
                    _ = try LocalTransferFile.selected([file.url])
                    DispatchQueue.main.async { self?.setStage(.uploading, detail: "Передаю \(file.name) · \(ProgressText.bytes(Double(file.size))) без перекодирования…") }
                    completion = try Self.transferMessage(file: file.url, target: target, runner: runner, onManual: { url, message in
                        DispatchQueue.main.async { NSWorkspace.shared.open(url); self?.appendLog(message) }
                    })
                }
                try runner.checkCancellation()
                let message = completion
                DispatchQueue.main.async { self?.finish(job: job, error: nil, message: message) }
            } catch {
                DispatchQueue.main.async { self?.finish(job: job, error: error, message: "") }
            }
        }
    }

    nonisolated private static func transferMessage(file: URL, target: URL, runner: ProcessRunner, onManual: (URL, String) -> Void) throws -> String {
        switch try VLCUploader.transfer(file: file, sharingURL: target, runner: runner) {
        case .uploaded: return "Передано в VLC: \(file.lastPathComponent)"
        case .manual(let url, let reason):
            onManual(url, reason)
            return "Требуется ручная передача: \(file.lastPathComponent)"
        }
    }

    private func finish(job: MediaJob, error: Error?, message: String) {
        guard queue.active?.id == job.id else { return }
        queue.finish(id: job.id)
        activeRunner = nil
        isBusy = false
        if let error {
            let cancelled = error is CancellationError
            let detail = cancelled ? "Текущая задача отменена." : error.localizedDescription
            setStage(cancelled ? .cancelled : .failed, detail: detail)
            appendLog("\(job.title): \(detail)")
            status = detail
        } else {
            setStage(.completed, fraction: 1, detail: message)
            appendLog("\(job.title): \(message)")
            status = message
        }
        startNext()
    }

    func cancel() {
        guard isBusy else { return }
        status = "Останавливаю текущую задачу… Ожидающие задачи сохраняются."
        activeRunner?.cancel()
    }

    func removePending(_ id: UUID) { queue.removePending(id: id) }
    func clearPending() { queue.clearPending() }

    func selectVideoFormat(_ id: String) { selectedVideoID = id; chooseAudioDefault() }
    func chooseLocalFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .audio]
        panel.allowsOtherFileTypes = true
        panel.directoryURL = destination
        panel.title = "Выберите файлы для VLC на iPad"
        panel.prompt = "Выбрать файлы"
        guard panel.runModal() == .OK else { return }
        do { localFiles = try LocalTransferFile.selected(panel.urls) }
        catch { errorMessage = error.localizedDescription }
    }

    func sendLocalFiles() {
        guard let target = sharingURL else { errorMessage = "Найдите VLC или введите адрес."; return }
        do { localFiles = try LocalTransferFile.selected(localFiles.map(\.url)) }
        catch { errorMessage = error.localizedDescription; return }
        queue.append(localFiles.map { file in
            MediaJob(title: file.name, detail: "В VLC · \(ProgressText.bytes(Double(file.size)))", payload: .transfer(file, target))
        })
        localFiles = []
        startNext()
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { destination = url }
    }
    func selectAll(_ selected: Bool, in episodes: [Episode]) {
        let ids = Set(episodes.map(\.id))
        if selected { selectedEpisodeIDs.formUnion(ids) } else { selectedEpisodeIDs.subtract(ids) }
    }
    private func chooseDefaults() {
        if !videoFormats.contains(where: { $0.formatID == selectedVideoID }) { selectedVideoID = videoFormats.first?.formatID ?? "" }
        chooseAudioDefault()
    }
    private func chooseAudioDefault() {
        guard selectedVideo?.isVideoOnly == true else { selectedAudioIDs = []; return }
        let audio = audioFormats
        let track = audio.first { ($0.formatNote ?? "").localizedCaseInsensitiveContains("дубляж") }
            ?? audio.first { $0.formatID.hasSuffix("-1") } ?? audio.first
        selectedAudioIDs = track.map { [$0.formatID] } ?? []
    }
    private func setStage(_ stage: WorkflowStage, fraction: Double? = nil, detail: String) {
        self.stage = stage
        progressIsKnown = fraction != nil
        progress = min(1, max(0, fraction ?? 0))
        progressDetail = detail
    }
    private func appendLog(_ text: String) {
        logLines.append(text)
        if logLines.count > 300 { logLines.removeFirst(logLines.count - 300) }
    }
}
