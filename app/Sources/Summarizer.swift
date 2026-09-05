// summarize.py, driven from the UI without ever blocking it.
//
// The script talks to a local Ollama and takes 30-60s, so the two failure modes
// that matter are "Ollama isn't there" and "it is there but never answers".
// Both end in a sentence the user can act on, never in a spinner that spins
// forever: the server is probed before we spawn anything, the run is cancellable,
// and it is killed at a hard ceiling.
import SwiftUI

@MainActor
final class Summarizer: ObservableObject {
    enum State: Equatable {
        case idle
        case running
        case ready(Summary, fromCache: Bool)
        case failed(String, hint: String)

        static func == (a: State, b: State) -> Bool {
            switch (a, b) {
            case (.idle, .idle), (.running, .running): return true
            case let (.ready(_, x), .ready(_, y)): return x == y
            case let (.failed(m, h), .failed(n, i)): return m == n && h == i
            default: return false
            }
        }
    }

    @Published private(set) var state = State.idle
    @Published private(set) var elapsed: TimeInterval = 0

    private var proc: Process?
    private var ticker: Timer?
    private static let ceiling: TimeInterval = 360  // ponytail: a run this long is a hang

    static let ollamaURL = URL(string: "http://localhost:11434/api/tags")!

    // MARK: - Cache

    /// Sits next to the wav and the transcript, so deleting a recording takes
    /// its summaries with it. One file per template: switching from Standard
    /// to Standup and back should not mean waiting for the model twice, and a
    /// Standup summary overwriting the Standard one would silently discard a
    /// minute the user already spent.
    static func cacheURL(_ id: String, template: String = SummaryTemplates.defaultID) -> URL {
        let suffix = template == SummaryTemplates.defaultID ? "" : ".\(template)"
        return Paths.recordings.appendingPathComponent("\(id).summary\(suffix).md")
    }

    /// Every summary file this recording could have left behind.
    static func cacheURLs(_ id: String) -> [URL] {
        let dir = Paths.recordings
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names
            .filter { $0.hasPrefix("\(id).summary") && $0.hasSuffix(".md") }
            .map { dir.appendingPathComponent($0) }
    }

    /// Load a previous run, if the transcript hasn't changed under it.
    func loadCached(_ id: String, template: String = SummaryTemplates.defaultID) {
        let cache = Summarizer.cacheURL(id, template: template)
        let txt = Paths.recordings.appendingPathComponent("\(id).txt")
        guard let md = try? String(contentsOf: cache, encoding: .utf8), !md.isEmpty,
              let cachedAt = mtime(cache) else { return }
        if let wroteAt = mtime(txt), wroteAt > cachedAt { return }
        let s = Summary(markdown: md)
        if !s.isEmpty { state = .ready(s, fromCache: true) }
    }

    private func mtime(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // MARK: - Run

    func cancel() {
        proc?.terminate()
        proc = nil
        stopClock()
        state = .idle
    }

    func run(id: String, template: String = SummaryTemplates.defaultID,
             instructions: String = "") {
        let provider = AISettings.providerID
        let model = AISettings.model(for: provider)
        guard state != .running else { return }
        let txt = Paths.recordings.appendingPathComponent("\(id).txt")
        guard let raw = try? String(contentsOf: txt, encoding: .utf8),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .failed("There is no transcript text to summarise.",
                            hint: "Re-transcribe the recording first."); return
        }
        let script = Paths.root.appendingPathComponent("summarize.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            state = .failed("summarize.py is missing.",
                            hint: "Expected it at \(script.path)"); return
        }

        state = .running
        elapsed = 0
        startClock()

        Task.detached(priority: .userInitiated) { [weak self] in
            // Only Ollama has a server to be down. Probing it when the user
            // picked Claude or Codex would refuse to summarise for a reason
            // that has nothing to do with the engine they chose.
            if provider == "ollama", let down = await Summarizer.ollamaUnreachable() {
                await self?.finish(.failed(down.0, hint: down.1))
                return
            }
            let out = await self?.spawn(script: script, transcript: txt.path,
                                        template: template, instructions: instructions,
                                        provider: provider, model: model)
            guard let out else { return }
            await MainActor.run { [weak self] in
                guard let self, self.state == .running else { return }   // cancelled
                self.stopClock()
                guard out.code == 0 else {
                    let err = out.err.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.state = .failed(err.isEmpty ? "summarize.py exited with code \(out.code)."
                                                     : String(err.prefix(400)),
                                         hint: "Run it in Terminal for the full output.")
                    return
                }
                let s = Summary(markdown: out.text)
                guard !s.isEmpty else {
                    self.state = .failed("The model returned nothing usable.",
                                         hint: "Try again, or a different model with --model.")
                    return
                }
                try? out.text.write(to: Summarizer.cacheURL(id, template: template),
                                    atomically: true, encoding: .utf8)
                self.state = .ready(s, fromCache: false)
            }
        }
    }

    private func finish(_ s: State) {
        stopClock()
        state = s
    }

    private struct Output { let text: String, err: String, code: Int32 }

    /// Blocking, but only on a detached task. stdout is drained on its own
    /// queue: a summary big enough to fill the 64K pipe buffer would otherwise
    /// deadlock against waitUntilExit().
    private nonisolated func spawn(script: URL, transcript: String,
                                   template: String, instructions: String,
                                   provider: String, model: String) async -> Output {
        await withCheckedContinuation { k in
            DispatchQueue.global(qos: .userInitiated).async {
                let python = URL(fileURLWithPath: Paths.python)
                let p = Process()
                p.executableURL = python
                var argv = ["-B", script.path, transcript, "--template", template,
                            "--provider", provider]
                // Empty means "the provider's own default", which is the only
                // correct value for Claude and Codex.
                if !model.isEmpty { argv += ["--model", model] }
                // Only pass it when there is something to say; an empty
                // --instructions would put a stray blank line in the prompt.
                if !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    argv += ["--instructions", instructions]
                }
                p.arguments = argv
                p.currentDirectoryURL = Paths.root
                var env = ProcessInfo.processInfo.environment
                env["PYTHONUNBUFFERED"] = "1"
                p.environment = env
                let o = Pipe(), e = Pipe()
                p.standardOutput = o
                p.standardError = e
                do { try p.run() } catch {
                    k.resume(returning: Output(text: "", err: "cannot run python3: \(error.localizedDescription)",
                                               code: 127)); return
                }
                Task { @MainActor [weak self] in self?.proc = p }
                let deadline = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + Summarizer.ceiling, execute: deadline)
                // Both pipes drained at once; whichever fills first must not
                // block the other, or the child stalls writing into a full one.
                var err = Data()
                let g = DispatchGroup()
                DispatchQueue.global().async(group: g) {
                    err = e.fileHandleForReading.readDataToEndOfFile()
                }
                let out = o.fileHandleForReading.readDataToEndOfFile()
                g.wait()
                p.waitUntilExit()
                deadline.cancel()
                k.resume(returning: Output(text: String(decoding: out, as: UTF8.self),
                                           err: String(decoding: err, as: UTF8.self),
                                           code: p.terminationStatus))
            }
        }
    }

    /// nil when Ollama answers. Localhost only — nothing here reaches the network.
    static func ollamaUnreachable() async -> (String, String)? {
        var req = URLRequest(url: ollamaURL)
        req.timeoutInterval = 3
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                return ("Ollama answered, but not with a model list.",
                        "Check `ollama serve` on port 11434.")
            }
            return nil
        } catch {
            return ("Ollama isn't answering on \(ollamaURL.host ?? "localhost"):\(ollamaURL.port ?? 11434).",
                    "Start it with `ollama serve`, or install it from ollama.com. "
                    + "Summaries run entirely on this Mac.")
        }
    }

    // MARK: - Clock

    private func startClock() {
        ticker?.invalidate()
        let t0 = Date()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.elapsed = Date().timeIntervalSince(t0)
                if self.elapsed > Summarizer.ceiling, self.state == .running {
                    self.proc?.terminate()
                    self.finish(.failed("The model did not finish within \(Int(Summarizer.ceiling / 60)) minutes.",
                                        hint: "Ollama may be stuck. Check `ollama ps`, then try again."))
                }
            }
        }
    }

    private func stopClock() { ticker?.invalidate(); ticker = nil }
}
