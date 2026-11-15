import Foundation
import Combine

struct VLCDevice: Identifiable, Equatable {
    let name: String
    let url: URL
    var id: String { url.absoluteString }
}

final class VLCDiscovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published private(set) var devices: [VLCDevice] = []
    @Published private(set) var isSearching = false
    @Published private(set) var status = "Включите VLC → Сеть → Sharing via Wi‑Fi на iPad."
    var onDevice: ((VLCDevice) -> Void)?

    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var probes: [String: URLSessionDataTask] = [:]
    private var timer: Timer?
    private var generation = UUID()

    override init() {
        super.init()
        browser.delegate = self
    }

    func search() {
        stop()
        devices = []
        isSearching = true
        status = "Ищу VLC через Bonjour…"
        browser.searchForServices(ofType: "_http._tcp.", inDomain: "local.")
        probeKnownNeighbors()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            self?.finish()
        }
    }

    func stop() {
        generation = UUID()
        timer?.invalidate()
        browser.stop()
        services.forEach { $0.stop() }
        services.removeAll()
        probes.values.forEach { $0.cancel() }
        probes.removeAll()
        isSearching = false
    }

    private func finish() {
        let count = devices.count
        stop()
        status = count == 0
            ? "VLC не найден. Включите Sharing via Wi‑Fi; Mac и iPad должны быть в одной сети. Можно указать адрес вручную."
            : "Найдено устройств с VLC: \(count)."
    }

    static func neighborAddresses(in output: String) -> [String] {
        var result: [String] = []
        for line in output.split(separator: "\n") where !line.contains("permanent") {
            guard let start = line.firstIndex(of: "("), let end = line.firstIndex(of: ")"), start < end else { continue }
            let address = String(line[line.index(after: start)..<end])
            let parts = address.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { continue }
            let isPrivate = parts[0] == 10
                || (parts[0] == 192 && parts[1] == 168)
                || (parts[0] == 172 && (16...31).contains(parts[1]))
                || (parts[0] == 169 && parts[1] == 254)
            guard isPrivate, parts[3] != 0, parts[3] != 255, !result.contains(address) else { continue }
            result.append(address)
            if result.count == 32 { break }
        }
        return result
    }

    private func probeKnownNeighbors() {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        process.arguments = ["-an"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            for address in Self.neighborAddresses(in: String(decoding: output, as: UTF8.self)) {
                for port in [80, 8080] {
                    var components = URLComponents()
                    components.scheme = "http"
                    components.host = address
                    components.port = port
                    components.path = "/"
                    guard let url = components.url else { continue }
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 3
                    verify(name: "VLC (\(address))", url: url, request: request)
                }
            }
        } catch {
            status = "Поиск через Bonjour… Таблица соседей недоступна."
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        stop()
        status = "Bonjour недоступен. Проверьте разрешение «Локальная сеть» для KinoPubDL в Системных настройках."
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard isSearching, let host = sender.hostName, sender.port > 0 else { return }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = sender.port
        components.path = "/"
        guard let url = components.url, probes[url.absoluteString] == nil else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        verify(name: sender.name, url: url, request: request)
    }

    private func verify(name: String, url: URL, request: URLRequest) {
        guard isSearching, probes[url.absoluteString] == nil else { return }
        let searchID = generation
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard error == nil, let data, let response = response as? HTTPURLResponse,
                  response.statusCode == 200,
                  VLCUploader.isVLCSharingPage(String(decoding: data, as: UTF8.self)) else { return }
            let device = VLCDevice(name: name, url: url)
            DispatchQueue.main.async {
                guard let self, self.isSearching, self.generation == searchID,
                      !self.devices.contains(where: { $0.id == device.id }) else { return }
                self.devices.append(device)
                self.status = "Найден VLC: \(device.name)"
                self.onDevice?(device)
            }
        }
        probes[url.absoluteString] = task
        task.resume()
    }
}
