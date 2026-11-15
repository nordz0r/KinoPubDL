import SwiftUI
import AppKit

@MainActor
struct ContentView: View {
    @StateObject private var model = DownloaderModel()
    @StateObject private var discovery = VLCDiscovery()

    private var seasons: [Int] {
        Array(Set(model.episodes.compactMap(\.seasonNumber))).sorted()
    }

    private var editorContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(spacing: 8) {
                TextField("Вставьте ссылку kino.watch или kino.pub", text: $model.urlText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(model.lookup)
                Button("Найти") { model.lookup() }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(model.isLookingUp)
            }

            authorizationPanel

            HStack {
                if model.isLookingUp { ProgressView().controlSize(.small) }
                Text(model.lookupStatus).font(.caption).foregroundStyle(.secondary)
            }

            if !model.toolsReady {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Для скачивания нужны yt-dlp, ffmpeg и плагин KinoPub. Передача файлов с диска работает без них.")
                        .foregroundStyle(.secondary)
                    Button("Установить yt-dlp и плагин через uv") { model.installYTDLPViaUV() }
                        .disabled(model.isBusy || model.isLookingUp || !model.canInstallViaUV)
                    if !model.canInstallViaUV { Text("uv не найден. Поставьте uv и Homebrew ffmpeg.").font(.caption).foregroundStyle(.secondary) }
                }
                .padding(12)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 9))
            }

            if !model.episodes.isEmpty {
                HStack(alignment: .top, spacing: 18) {
                    episodePanel
                    optionsPanel
                }
                HStack {
                    Button("Загрузить форматы выбранной серии") { model.loadFormats() }
                        .disabled(model.isLookingUp || model.selectedEpisodes.isEmpty)
                    Spacer()
                    Button("Папка…") { model.chooseDestination() }
                    Text(model.destination.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("После скачивания создать H.265-копию", isOn: $model.transcodeToHEVC)
                    Text("CRF 28, medium. Разрешение и звук сохраняются. Если источник уже H.265, повторного кодирования и удаления нет.")
                        .font(.caption2).foregroundStyle(.secondary)
                    if model.transcodeToHEVC {
                        Toggle("Удалить исходник после проверки (в Корзину)", isOn: $model.deleteOriginalAfterEncoding)
                                .padding(.leading, 18)
                        Text(model.deleteOriginalAfterEncoding
                             ? "Исходник убирается только после полной проверки новой копии. Его можно восстановить из Корзины; место освободится после её очистки."
                             : "Исходник остаётся рядом с H.265-копией.")
                            .font(.caption2).foregroundStyle(.secondary).padding(.leading, 18)
                    }
                }
            } else {
                Spacer()
                Text(model.lookupStatus)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Spacer()
            }

            iPadPanel
            queuePanel

            if !model.logLines.isEmpty {
                DisclosureGroup("Журнал (\(model.logLines.count))") {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(model.logLines.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 100)
                }
            }
            Text(model.episodes.isEmpty
                 ? "Выбранные файлы копируются в VLC без изменения содержимого; оригиналы остаются на Mac."
                 : model.transcodeToHEVC
                 ? (model.deleteOriginalAfterEncoding
                    ? "На iPad отправляется проверенная H.265-копия. Исходник после успешного перекодирования перемещается в Корзину."
                    : "На iPad отправляется проверенная H.265-копия после завершения перекодирования; оригинал остаётся на Mac.")
                 : "Скачивается исходный поток без перекодирования; видео и звук только объединяются при необходимости.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(18)
    }

    var body: some View {
        ScrollView { editorContent }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !model.episodes.isEmpty || model.isBusy || !model.localFiles.isEmpty || model.stage != .idle {
                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                    pipelineProgressPanel
                    HStack {
                        Text(model.status).font(.caption).lineLimit(2)
                        Spacer()
                        if model.isBusy {
                            Button("Отменить текущую") { model.cancel() }
                        }
                        if !model.episodes.isEmpty {
                            Button("Добавить в очередь") { model.download() }
                                .keyboardShortcut(.defaultAction)
                                .disabled(model.isLookingUp || model.selectedEpisodes.isEmpty || model.selectedVideo == nil)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
                .background(.bar)
            }
        }
        .tint(Color(red: 0.13, green: 0.47, blue: 0.40))
        .onAppear {
            discovery.onDevice = { device in
                if model.vlcAddress.isEmpty { model.vlcAddress = device.url.absoluteString }
            }
            discovery.search()
        }
        .onChange(of: model.cookieBrowser) { _ in model.cookieBrowserChanged() }
        .onChange(of: model.sendToVLC) { enabled in
            if enabled { discovery.search() }
        }
        .alert("Ошибка", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Неизвестная ошибка")
        }
    }

    private var authorizationPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Авторизация Kino.Pub").font(.subheadline.weight(.semibold))
            HStack {
                Picker("Cookies из браузера", selection: $model.cookieBrowser) {
                    ForEach(CookieBrowser.allCases) { browser in Text(browser.title).tag(browser) }
                }
                .disabled(model.isLookingUp)
                Button("Прочитать cookies и проверить вход") { model.checkBrowserCookies() }
                    .disabled(model.isLookingUp || !model.toolsReady)
            }
            Text(model.authorizationStatus).font(.caption).foregroundStyle(.secondary)
            Text("Нужны действующая сессия и доступ к видео в вашем аккаунте. Пароль вводится только на сайте, cookies не экспортируются. Safari может потребовать полный доступ к диску, Chrome/Edge/Brave — разрешение Связки ключей.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(11)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 9))
    }

    private var queuePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Очередь · ожидает: \(model.queue.pending.count)").font(.headline)
                Spacer()
                if !model.queue.pending.isEmpty {
                    Button("Убрать ожидающие") { model.clearPending() }
                }
            }
            if let active = model.queue.active {
                Label(active.title, systemImage: "arrow.down.circle.fill")
                    .font(.subheadline.weight(.medium))
                Text(active.detail).font(.caption).foregroundStyle(.secondary)
            }
            if model.queue.pending.isEmpty {
                Text(model.isBusy ? "Можно добавить следующую ссылку или файлы с диска — текущая задача продолжится." : "Добавьте выбранные серии или файлы для VLC.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.queue.pending) { job in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(job.title).lineLimit(1)
                                    Text(job.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer()
                                Button("Убрать") { model.removePending(job.id) }.buttonStyle(.borderless)
                            }
                        }
                    }
                }.frame(maxHeight: 160)
            }
            Text("Настройки фиксируются при добавлении. Задачи выполняются по одной. Очередь хранится до закрытия приложения.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(11)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 9))
    }

    private var pipelineProgressPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.stage.title).font(.subheadline.weight(.semibold))
                Spacer()
                if model.progressIsKnown {
                    Text("\(Int(model.progress * 100))%")
                        .font(.subheadline.monospacedDigit())
                }
            }
            if model.progressIsKnown {
                ProgressView(value: model.progress)
            } else if model.isBusy {
                ProgressView().progressViewStyle(.linear)
            } else {
                ProgressView(value: 0)
            }
            Text(model.progressDetail.isEmpty ? "Сначала скачивание, затем — H.265, если включена галка." : model.progressDetail)
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
            if !model.lastComparison.isEmpty {
                Text(model.lastComparison).font(.caption).textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("KinoPubDL").font(.largeTitle.weight(.semibold))
            Text("Скачивание фильмов и сериалов с Kino.Pub через авторизованную сессию браузера.")
                .font(.callout).foregroundStyle(.secondary)
            Text(model.title.isEmpty ? "Видео сохраняются в исходном качестве и кодеке." : model.title)
                .foregroundStyle(.secondary)
        }
    }

    private var episodePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Серии (\(model.selectedEpisodeIDs.count)/\(model.episodes.count))").font(.headline)
                Spacer()
                Button("Все") { model.selectAll(true, in: model.episodes) }.buttonStyle(.borderless)
                Button("Ни одной") { model.selectAll(false, in: model.episodes) }.buttonStyle(.borderless)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(seasons, id: \.self) { season in
                        let group = model.episodes.filter { $0.seasonNumber == season }
                        HStack {
                            Text("Сезон \(season)").font(.subheadline.weight(.medium))
                            Spacer()
                            Button("✓") { model.selectAll(true, in: group) }.buttonStyle(.borderless)
                            Button("−") { model.selectAll(false, in: group) }.buttonStyle(.borderless)
                        }
                        ForEach(group) { episode in episodeRow(episode) }
                    }
                    if seasons.isEmpty {
                        ForEach(model.episodes) { episode in episodeRow(episode) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
            }
            .frame(minWidth: 370, maxWidth: .infinity, minHeight: 250)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.quaternary))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func episodeRow(_ episode: Episode) -> some View {
        Toggle(isOn: Binding(
            get: { model.selectedEpisodeIDs.contains(episode.id) },
            set: { if $0 { model.selectedEpisodeIDs.insert(episode.id) } else { model.selectedEpisodeIDs.remove(episode.id) } }
        )) {
            Text(episode.displayName).lineLimit(1).help(episode.title)
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 7)
    }

    private var optionsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Форматы источника").font(.headline)
            if model.videoFormats.isEmpty {
                Text("Загрузите форматы выбранной серии.").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Качество / кодек").font(.subheadline.weight(.medium))
                ForEach(model.videoFormats) { format in
                    Button {
                        model.selectVideoFormat(format.formatID)
                    } label: {
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: model.selectedVideoID == format.formatID ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(.tint)
                            Text(format.displayName).font(.caption).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Divider()
                Text("Аудиодорожки (можно несколько)").font(.subheadline.weight(.medium))
                if model.audioFormats.isEmpty {
                    Text(model.selectedVideo?.hasAudio == true
                         ? "Аудио уже включено в видеопоток."
                         : "Отдельные аудиодорожки не найдены. Обновите форматы или выберите другой поток.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(model.audioFormats) { format in
                        Toggle(isOn: Binding(
                            get: { model.selectedAudioIDs.contains(format.formatID) },
                            set: { if $0 { model.selectedAudioIDs.insert(format.formatID) } else { model.selectedAudioIDs.remove(format.formatID) } }
                        )) {
                            Text(format.displayName).font(.caption).lineLimit(2)
                        }.toggleStyle(.checkbox)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(minWidth: 380, maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 9))
    }

    private var iPadPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("VLC на iPad", systemImage: "ipad").font(.headline)
            HStack {
                Button(discovery.isSearching ? "Поиск VLC…" : "Найти iPad в сети") { discovery.search() }
                    .disabled(discovery.isSearching)
                if discovery.isSearching { ProgressView().controlSize(.small) }
                Text(discovery.status).font(.caption).foregroundStyle(.secondary)
            }
            if !discovery.devices.isEmpty {
                Picker("VLC в сети", selection: $model.vlcAddress) {
                    Text("Выберите устройство").tag("")
                    if !model.vlcAddress.isEmpty && !discovery.devices.contains(where: { $0.url.absoluteString == model.vlcAddress }) {
                        Text("Указанный адрес: \(model.vlcAddress)").tag(model.vlcAddress)
                    }
                    ForEach(discovery.devices) { device in
                        Text("\(device.name) — \(device.url.host ?? "")").tag(device.url.absoluteString)
                    }
                }
            }
            HStack {
                TextField("Адрес Wi‑Fi Sharing, например http://192.168.1.10:8080", text: $model.vlcAddress)
                    .textFieldStyle(.roundedBorder)
                Button("Как включить?") {
                    if let url = URL(string: "https://docs.videolan.me/vlc-ios-user/gettingstarted/media_synchronization.html") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Text("На iPad включите VLC → Сеть → Sharing via Wi‑Fi и оставьте VLC открытым. Mac и iPad должны быть в одной сети.")
                .font(.caption2).foregroundStyle(.secondary)
            if !model.episodes.isEmpty {
                Toggle("После скачивания передать результат в VLC", isOn: $model.sendToVLC)
            }
            Divider()
            HStack {
                Button("Выбрать файл с диска…") { model.chooseLocalFiles() }
                Text("Без скачивания и перекодирования").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            if !model.localFiles.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(model.localFiles) { file in
                            HStack {
                                Text(file.name).lineLimit(1).truncationMode(.middle).help(file.url.path)
                                Spacer()
                                Text(ProgressText.bytes(Double(file.size))).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.frame(maxHeight: 100)
                HStack {
                    Text("Выбрано файлов: \(model.localFiles.count)").font(.caption)
                    Button("Очистить") { model.localFiles = [] }
                    Spacer()
                    Button("Добавить передачу в очередь") { model.sendLocalFiles() }
                        .disabled(model.sharingURL == nil)
                }
            }
        }
        .padding(11)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 9))
    }
}
