// Getting a decoder onto the machine, at first run instead of in the installer.
//
// The 0.1 DMG was 1.4 GB, and essentially all of it was one model file. It is
// downloaded now. It cannot be downloaded *into* the bundle: writing anything
// under Contents/Resources breaks the code signature the installer just
// verified, and the launch after that is refused with no useful message. So it
// lands under the support directory, and languages.py looks in both places -
// a source checkout keeps using the models/ it already built with.
//
// Two failures are specifically guarded here because both have been seen from
// CDNs in the wild and both leave something that *looks* like a model:
// a truncated body, and an HTML error page served with a 200. Either one
// reaches whisper-cli as a corrupt file and the app reports "transcription
// failed" for a reason the user cannot possibly guess. Size and the published
// SHA-256 are both checked before anything is moved into place.
//
// This file deliberately depends on nothing else in the app, so
// app/model-selftest can compile and exercise it against a local HTTP server
// without dragging in SwiftUI, EventKit and the recording library.
import Foundation
import Combine
import CryptoKit

struct ModelSpec: Identifiable, Equatable, Sendable {
    /// The filename languages.py resolves. Not a display name - if this drifts
    /// the download succeeds and the decoder still says the model is missing.
    let id: String
    let label: String
    let blurb: String
    let url: URL
    let bytes: Int64
    /// Hugging Face publishes this as the LFS object id, so it can be checked
    /// against the API rather than trusted from a comment here.
    let sha256: String

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

enum ModelCatalog {
    // Verified 2026-09-05: both URLs return 200 with content-length 1624555275
    // and these SHA-256s match the two .bin files this project has been
    // decoding with since the beginning. Do not edit a URL without re-checking
    // it - a link that 404s on a stranger's first launch is the whole risk of
    // moving the model out of the installer.
    static let hebrew = ModelSpec(
        id: "ivrit-large-v3-turbo.bin",
        label: "Hebrew — ivrit-ai fine-tune",
        blurb: "large-v3-turbo fine-tuned on Hebrew. The better decoder for Hebrew, "
             + "including Hebrew sentences carrying English technical terms.",
        url: URL(string: "https://huggingface.co/ivrit-ai/whisper-large-v3-turbo-ggml/resolve/main/ggml-model.bin")!,
        bytes: 1_624_555_275,
        sha256: "c8090411113357097bfafc2b8e228ec1639fa7f5fe4ecb5d054ac0ccef8641b1")

    static let multilingual = ModelSpec(
        id: "vanilla-large-v3-turbo.bin",
        label: "Multilingual — stock large-v3-turbo",
        blurb: "The whisper.cpp release of large-v3-turbo. The better decoder for "
             + "every language that is not Hebrew, and what `auto` detects with.",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!,
        bytes: 1_624_555_275,
        sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69")

    static let all = [hebrew, multilingual]

    /// Mirrors languages.support_dir() / "models". Passed in rather than read
    /// from Paths so this file stays free of the rest of the app.
    static func directory(under support: URL) -> URL {
        support.appendingPathComponent("models")
    }
}

enum ModelState: Equatable {
    case absent
    /// Bytes of a stopped download still on disk. Resumed, not thrown away.
    case partial(Int64)
    case downloading(received: Int64, total: Int64)
    case verifying
    case installed
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .downloading, .verifying: return true
        default: return false
        }
    }
}

/// Downloads a model to `<directory>/<id>.part`, verifies it, and only then
/// renames it to `<directory>/<id>`. A cancelled or failed run can therefore
/// never leave a half file where the decoder will find it.
final class ModelDownloads: NSObject, ObservableObject {
    @Published private(set) var state: [String: ModelState] = [:]

    let directory: URL
    /// Read-only places a model may already exist - the checkout's models/ in a
    /// development build. Never written to.
    private let alsoSearch: [URL]

    private var tasks: [String: URLSessionDataTask] = [:]
    private var sinks: [Int: Sink] = [:]
    private lazy var session: URLSession = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1     // sinks are only touched here
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        // A 1.5 GB download over a bad hotel connection is not a stalled one.
        config.timeoutIntervalForResource = 24 * 60 * 60
        return URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }()

    init(directory: URL, alsoSearch: [URL] = []) {
        self.directory = directory
        self.alsoSearch = alsoSearch
        super.init()
    }

    // MARK: - Where things are

    func installedURL(_ spec: ModelSpec) -> URL? {
        // Checkout first, matching languages.model_path(): if a developer has
        // the file in models/ the app must agree that it is installed.
        for dir in alsoSearch + [directory] {
            let candidate = dir.appendingPathComponent(spec.id)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    func targetURL(_ spec: ModelSpec) -> URL { directory.appendingPathComponent(spec.id) }
    private func partURL(_ spec: ModelSpec) -> URL {
        directory.appendingPathComponent(spec.id + ".part")
    }

    /// Re-read the disk. Called on appear so a download finished in a previous
    /// launch shows as installed instead of being started again.
    func refresh(_ specs: [ModelSpec] = ModelCatalog.all) {
        for spec in specs {
            // .failed is not busy, but refreshing past it wipes the one panel
        // that says what went wrong and where to put the file by hand - and
        // switching to a browser to go and fetch it is exactly what triggers
        // the refresh. Keep it until the user acts on it.
        if state[spec.id]?.isBusy == true { continue }
        if case .failed = state[spec.id] { continue }
            if installedURL(spec) != nil {
                set(spec.id, .installed)
            } else {
                let onDisk = fileSize(partURL(spec))
                set(spec.id, onDisk > 0 ? .partial(onDisk) : .absent)
            }
        }
    }

    // MARK: - Transfer

    func start(_ spec: ModelSpec) {
        guard tasks[spec.id] == nil else { return }
        if installedURL(spec) != nil { set(spec.id, .installed); return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            set(spec.id, .failed("cannot create \(directory.path): \(error.localizedDescription)"))
            return
        }

        let part = partURL(spec)
        let resumeFrom = fileSize(part)
        var request = URLRequest(url: spec.url)
        if resumeFrom > 0 { request.setValue("bytes=\(resumeFrom)-", forHTTPHeaderField: "Range") }

        let task = session.dataTask(with: request)
        tasks[spec.id] = task
        set(spec.id, .downloading(received: resumeFrom, total: spec.bytes))
        session.delegateQueue.addOperation { [weak self] in
            self?.sinks[task.taskIdentifier] = Sink(spec: spec, part: part, resumeFrom: resumeFrom)
            task.resume()
        }
    }

    /// Stops the transfer and keeps the .part file, so pressing Download again
    /// - now or after a relaunch - continues instead of starting over.
    func cancel(_ spec: ModelSpec) {
        tasks[spec.id]?.cancel()
    }

    // MARK: - Internals

    private func set(_ id: String, _ new: ModelState) {
        if Thread.isMainThread {
            if state[id] != new { state[id] = new }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.state[id] != new else { return }
                self.state[id] = new
            }
        }
    }

    private func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    /// Streamed rather than read whole: the file is 1.5 GB and a resumed
    /// download has no in-memory hash state to carry over from last launch.
    private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Per-task scratch. Only ever touched on the session's serial queue.
    private final class Sink {
        let spec: ModelSpec
        let part: URL
        var handle: FileHandle?
        var received: Int64
        var announced: Int64
        var problem: String?

        init(spec: ModelSpec, part: URL, resumeFrom: Int64) {
            self.spec = spec
            self.part = part
            self.received = resumeFrom
            self.announced = resumeFrom
        }
    }
}

extension ModelDownloads: URLSessionDataDelegate {
    // Hugging Face answers with a 302 to a CDN. URLSession does not always carry
    // custom headers across a redirect, and a dropped Range header restarts a
    // 1.5 GB download from zero without saying so.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        var next = request
        if let range = task.originalRequest?.value(forHTTPHeaderField: "Range") {
            next.setValue(range, forHTTPHeaderField: "Range")
        }
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let sink = sinks[dataTask.taskIdentifier] else {
            completionHandler(.cancel); return
        }
        func refuse(_ why: String) {
            sink.problem = why
            completionHandler(.cancel)
        }
        guard let http = response as? HTTPURLResponse else {
            refuse("not an HTTP response"); return
        }

        var start: Int64 = 0
        var total: Int64 = 0
        // The status is read before the content type, or a 404 whose body is
        // text/plain gets reported as "the server sent text/plain" and the user
        // goes looking for a mangled download instead of a dead URL.
        switch http.statusCode {
        case 206:
            guard let header = http.value(forHTTPHeaderField: "Content-Range"),
                  let parsed = Self.parseContentRange(header) else {
                refuse("the server sent a partial response with no Content-Range")
                return
            }
            (start, total) = parsed
            guard start == sink.received else {
                refuse("resume mismatch: asked for byte \(sink.received), got \(start)")
                return
            }
        case 200:
            // The server ignored our Range and is sending the whole file. Start
            // the .part over rather than appending to what is already there.
            start = 0
            total = http.expectedContentLength > 0 ? Int64(http.expectedContentLength) : 0
            sink.received = 0
                    sink.announced = 0
        default:
            refuse("HTTP \(http.statusCode) from \(sink.spec.url.host ?? "the server")")
            return
        }

        // An HTML error page served with a 200 is the failure that looks most
        // like success: 3 KB of markup lands at the model path and whisper-cli
        // dies on it later with something unreadable.
        let mime = (http.mimeType ?? "").lowercased()
        guard !mime.contains("html"), !mime.hasPrefix("text/") else {
            refuse("the server sent \(mime) instead of the model — check the URL")
            return
        }

        // Catching a moved or replaced upstream file here beats hashing 1.5 GB
        // first and reporting it twenty minutes later.
        if total > 0 && total != sink.spec.bytes {
            refuse("expected \(sink.spec.bytes) bytes, the server offers \(total)")
            return
        }

        do {
            let fm = FileManager.default
            if start == 0 || !fm.fileExists(atPath: sink.part.path) {
                fm.createFile(atPath: sink.part.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: sink.part)
            try handle.truncate(atOffset: UInt64(start))
            try handle.seekToEnd()
            sink.handle = handle
        } catch {
            refuse("cannot write \(sink.part.lastPathComponent): \(error.localizedDescription)")
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let sink = sinks[dataTask.taskIdentifier], let handle = sink.handle else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            sink.problem = "cannot write \(sink.part.lastPathComponent): \(error.localizedDescription)"
            dataTask.cancel()
            return
        }
        sink.received += Int64(data.count)
        // Publishing every chunk would put tens of thousands of updates through
        // SwiftUI. A step proportional to the file was worse: 1.5 GB / 200 is
        // 8 MB, and on a slow connection the bar sat still for half a minute at
        // a time and read as a hung download. Half a megabyte is ~3000 updates
        // for the whole model, spread over minutes.
        if sink.received - sink.announced >= 512 << 10 {
            sink.announced = sink.received
            set(sink.spec.id, .downloading(received: sink.received, total: sink.spec.bytes))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let sink = sinks.removeValue(forKey: task.taskIdentifier) else { return }
        try? sink.handle?.close()
        sink.handle = nil
        let id = sink.spec.id
        DispatchQueue.main.async { [weak self] in self?.tasks[id] = nil }

        // Our own refusals arrive here as a "cancelled" error, so they are read
        // first - otherwise a rejected HTML page would report as user cancel.
        if let why = sink.problem {
            try? FileManager.default.removeItem(at: sink.part)
            set(id, .failed(why))
            return
        }
        if let error = error as NSError?, error.domain == NSURLErrorDomain,
           error.code == NSURLErrorCancelled {
            set(id, .partial(sink.received))   // keep the .part; Download resumes it
            return
        }
        if let error {
            // The .part stays: a connection that died at 1.2 GB should not cost
            // the user 1.2 GB again. Pressing Download resumes from it.
            set(id, .failed(error.localizedDescription))
            return
        }

        set(id, .verifying)
        let spec = sink.spec
        let part = sink.part
        let onDisk = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? 0
        guard onDisk == spec.bytes else {
            // A truncated body is the other failure that looks like a model.
            try? FileManager.default.removeItem(at: part)
            set(id, .failed("download ended at \(onDisk) of \(spec.bytes) bytes — try again"))
            return
        }
        guard let digest = Self.sha256(of: part) else {
            set(id, .failed("cannot read \(part.lastPathComponent) back to verify it"))
            return
        }
        guard digest == spec.sha256 else {
            try? FileManager.default.removeItem(at: part)
            set(id, .failed("checksum mismatch — the file that arrived is not this model"))
            return
        }
        do {
            let final = directory.appendingPathComponent(spec.id)
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: part, to: final)
        } catch {
            set(id, .failed("cannot install the model: \(error.localizedDescription)"))
            return
        }
        set(id, .installed)
    }

    /// "bytes 100-999/1000" -> (100, 1000)
    static func parseContentRange(_ header: String) -> (Int64, Int64)? {
        let body = header.replacingOccurrences(of: "bytes ", with: "")
        let halves = body.split(separator: "/")
        guard halves.count == 2, let total = Int64(halves[1]) else { return nil }
        guard let first = halves[0].split(separator: "-").first, let start = Int64(first) else {
            return nil
        }
        return (start, total)
    }
}
