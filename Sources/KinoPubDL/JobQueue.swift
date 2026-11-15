import Foundation

struct DownloadJob {
    let episode: Episode
    let video: MediaFormat
    let audioIDs: Set<String>
    let destination: URL
    let encode: Bool
    let deleteOriginal: Bool
    let sharingURL: URL?
    var cookieBrowser: CookieBrowser = .safari
}

enum JobPayload {
    case download(DownloadJob)
    case transfer(LocalTransferFile, URL)
}

struct MediaJob: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let payload: JobPayload
}

struct SerialJobQueue<Job: Identifiable> where Job.ID: Equatable {
    private(set) var pending: [Job] = []
    private(set) var active: Job?

    mutating func append(_ jobs: [Job]) { pending.append(contentsOf: jobs) }

    mutating func startNext() -> Job? {
        guard active == nil, !pending.isEmpty else { return nil }
        let job = pending.removeFirst()
        active = job
        return job
    }

    mutating func finish(id: Job.ID) {
        guard active?.id == id else { return }
        active = nil
    }

    mutating func removePending(id: Job.ID) { pending.removeAll { $0.id == id } }
    mutating func clearPending() { pending.removeAll() }
}
