// Capture -> disk -> transcript, as two child processes we own.
//
// We deliberately do NOT re-implement the CoreAudio process tap. capture/tap.swift
// already solved it (and the TCC dance around it); we run its signed helper in
// `stream` mode and take 16 kHz mono PCM16 off its stdout. A spawned child
// inherits us as its responsible process, so the audio-capture grant the
// onboarding screen obtains is the one the helper runs under.
import SwiftUI
import EventKit

/// Everything that must not touch the main actor: the audio bytes arrive on a
/// CoreAudio-paced queue and are far too frequent to hop per buffer.
private final class PCMSink {
    private let wav: FileHandle
    private var bytes = 0
    private let toTranscriber: FileHandle?

    init?(wavURL: URL, transcriberInput: FileHandle?) {
        FileManager.default.createFile(atPath: wavURL.path, contents: PCMSink.header(0))
        guard let h = try? FileHandle(forWritingTo: wavURL) else { return nil }
        h.seekToEndOfFile()
        wav = h
        toTranscriber = transcriberInput
    }

    /// Returns the peak amplitude (0...1) of this chunk.
    func write(_ data: Data) -> Float {
        wav.write(data)
        bytes += data.count
        if let t = toTranscriber { try? t.write(contentsOf: data) }
        var peak: Int16 = 0
        data.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            // every 8th sample is plenty for a meter and keeps this cheap
            for i in stride(from: 0, to: s.count, by: 8) {
                let v = s[i] == Int16.min ? Int16.max : abs(s[i])
                if v > peak { peak = v }
            }
        }
        return Float(peak) / 32767
    }

    /// `padTo` is the wall-clock length of the recording. The tap stops
    /// producing IO the moment nothing is playing, so its stream can end early
    /// - a 72.5 s Zoom call once left a 26.9 s file. The microphone's file is
    /// always the true length, and when the two disagree every far-side line
    /// sits at the wrong time and attribution hands it to the local speaker.
    /// Pad the shortfall with silence so both files describe the same minute.
    func close(padTo seconds: Double = 0) {
        deliveredSeconds = Double(bytes) / (16_000 * 2)
        let want = Int(seconds * 16_000) * 2
        if want > bytes {
            var left = want - bytes
            while left > 0 {
                let n = min(left, 32_000)
                wav.write(Data(count: n))
                left -= n
            }
            bytes = want
        }
        try? wav.seek(toOffset: 0)
        wav.write(PCMSink.header(bytes))
        try? wav.close()
        try? toTranscriber?.close()
    }

    /// How much of the file the tap actually delivered, before any padding.
    private(set) var deliveredSeconds: Double = 0

    var seconds: Double { Double(bytes) / (16_000 * 2) }

    /// 16 kHz mono PCM16 canonical WAV header; sizes patched on close.
    private static func header(_ dataBytes: Int) -> Data {
        var d = Data()
        func str(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: Int) { var x = UInt32(truncatingIfNeeded: v).littleEndian
                             withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { var x = UInt16(truncatingIfNeeded: v).littleEndian
                             withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(36 + dataBytes); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        str("data"); u32(dataBytes)
        return d
    }
}

@MainActor
final class Recorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var level: Float = 0        // smoothed 0...1
    @Published private(set) var committed: [String] = []
    @Published private(set) var provisional = ""
    /// True while the saved file is being re-transcribed after recording stops.
    @Published private(set) var isFinalizing = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var lastError: String?

    private var tap: Process?
    private var micProc: Process?
    private var transcriber: Process?
    private var micTranscriber: Process?
    private var sink: PCMSink?
    private var startedAt: Date?
    private var wavName = ""
    private var ticker: Timer?
    private var lineBuf = Data()

    let library: Library
    private let eventStore = EKEventStore()

    init(library: Library) { self.library = library }

    // MARK: - Lifecycle

    func start() {
        guard !isRecording else { return }
        guard FileManager.default.fileExists(atPath: Paths.captureHelper.path) else {
            lastError = "capture helper missing at \(Paths.captureHelper.path)"; return
        }
        committed = []; provisional = ""; elapsed = 0; lastError = nil
        let id = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        wavName = "\(id).wav"
        startedAt = Date()

        let transcriberIn = startTranscriber()
        guard let sink = PCMSink(wavURL: Paths.recordings.appendingPathComponent(wavName),
                                 transcriberInput: transcriberIn) else {
            lastError = "cannot open output file"; return
        }
        self.sink = sink
        startMic()

        let p = Process()
        p.executableURL = Paths.captureHelper
        // Tap ONLY. Mixing the microphone into this stream made transcription
        // measurably worse than tap-only - even with echo cancellation the two
        // sources interfere and the decoder has to pick a sentence out of the
        // blend. The microphone is captured by a second process to its own
        // file, and the two are transcribed separately.
        p.arguments = ["stream"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Recorder.helperLog(wavName, tag: "tap")
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            let peak = sink.write(data)
            Task { @MainActor [weak self] in self?.meter(peak) }
        }
        do { try p.run() } catch {
            lastError = "capture failed: \(error.localizedDescription)"; return
        }
        tap = p
        isRecording = true
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let t = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(t)
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        ticker?.invalidate(); ticker = nil
        (tap?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        tap?.terminate(); tap = nil
        micProc?.terminate(); micProc = nil
        // Pad to wall clock, not to whatever the tap happened to deliver:
        // `seconds` used to be derived from the byte count, so a stalled tap
        // made the whole recording look short instead of making the gap visible.
        sink?.close(padTo: elapsed)
        let seconds = max(elapsed, sink?.seconds ?? elapsed)
        let delivered = sink?.deliveredSeconds ?? seconds
        sink = nil
        transcriber?.terminate(); transcriber = nil
        level = 0
        provisional = ""

        // a mis-click that starts and stops immediately is not a recording
        guard let started = startedAt, seconds >= 1 else {
            try? FileManager.default.removeItem(
                at: Paths.recordings.appendingPathComponent(wavName))
            startedAt = nil
            return
        }
        let calendarEnabled = UserDefaults.standard.object(forKey: "useCalendarTitles") as? Bool ?? true
        let title = (calendarEnabled ? calendarTitle(at: started, store: eventStore) : nil)
            ?? started.formatted(date: .abbreviated, time: .shortened)
        let rec = Recording(id: wavName.replacingOccurrences(of: ".wav", with: ""),
                            title: title, startedAt: started,
                            duration: seconds, wav: wavName)
        library.save(rec, transcript: committed)
        startedAt = nil
        // Say it out loud when the far side was only partly captured. Silence
        // here is what made a Zoom call look merely "bad at Hebrew" when in
        // fact two thirds of the other person had never reached the disk.
        if seconds >= 5, delivered < seconds * 0.8 {
            lastError = String(format:
                "System audio was only captured for %.0fs of this %.0fs call — "
                + "the other side is missing from the rest. "
                + "See %@.capture.log.", delivered, seconds, rec.id)
        }
        // The live transcript is a best-effort preview - its coverage swings
        // with decode timing. Re-transcribe the saved file in one pass now that
        // there is no real-time pressure, and replace the preview with it.
        finalize(rec)
    }

    /// Batch-transcribe the saved recording and replace the live preview.
    private var micName: String { wavName.replacingOccurrences(of: ".wav", with: "-you.wav") }

    private func finalize(_ rec: Recording) {
        let wav = Paths.recordings.appendingPathComponent(rec.wav)
        guard FileManager.default.fileExists(atPath: Paths.scribebotPy.path),
              FileManager.default.fileExists(atPath: wav.path) else { return }
        isFinalizing = true
        DispatchQueue.global(qos: .userInitiated).async {
            func transcribe(_ url: URL) -> String {
                guard FileManager.default.fileExists(atPath: url.path) else { return "" }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: Paths.python)
                p.arguments = ["-B", Paths.scribebotPy.path, "file", url.path]
                p.currentDirectoryURL = Paths.root
                let out = Pipe()
                p.standardOutput = out
                let err = Pipe()
                p.standardError = err
                do {
                    try p.run()
                    let d = out.fileHandleForReading.readDataToEndOfFile()
                    let e = err.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    if p.terminationStatus != 0 {
                        // Report it. Swallowing this is what let a SyntaxError
                        // under the wrong Python masquerade as a short recording.
                        let msg = String(decoding: e, as: UTF8.self)
                            .split(separator: "\n").last.map(String.init) ?? "exit \(p.terminationStatus)"
                        DispatchQueue.main.async { [weak self] in
                            self?.lastError = "Transcription failed: \(msg)"
                        }
                        return ""
                    }
                    return String(decoding: d, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } catch { return "" }
            }
            // Two sources, transcribed apart. Which side spoke is then known
            // without any diarization at all.
            let them = transcribe(wav)
            let you = transcribe(Paths.recordings.appendingPathComponent(
                rec.wav.replacingOccurrences(of: ".wav", with: "-you.wav")))
            var lines: [String] = []
            if !them.isEmpty { lines.append("Them: " + them) }
            if !you.isEmpty  { lines.append("You: " + you) }
            // Persist from THIS thread before touching the UI. Hopping to the
            // main queue first meant a quit - or anything killing the app in the
            // second it takes to decode - lost the accurate transcript and left
            // the live preview's first fragment on disk as the final record.
            if !lines.isEmpty {
                Library.writeTranscript(rec, lines: lines)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isFinalizing = false
                guard !lines.isEmpty else { return }
                self.library.save(rec, transcript: lines)
                self.committed = lines
            }
        }
    }

    /// stderr for one of the capture helpers, appended to a log beside the
    /// recording. This used to be FileHandle.nullDevice, and that single line
    /// is why three shipped bugs were invisible: the helper prints its input
    /// device, its clock source, every sample rate, the Bluetooth low-quality
    /// warning, each tap stall, and every hard failure - and all of it was
    /// thrown away, so a broken recording and a good one looked identical.
    nonisolated static func helperLog(_ wavName: String, tag: String) -> Any {
        let id = wavName.replacingOccurrences(of: ".wav", with: "")
        let url = Paths.recordings.appendingPathComponent("\(id).capture.log")
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: url) else { return FileHandle.nullDevice }
        h.seekToEndOfFile()
        let stamp = ISO8601DateFormatter().string(from: Date())
        h.write("\n===== \(tag) \(stamp) =====\n".data(using: .utf8)!)
        return h
    }

    /// Capture the local voice to its own file AND feed it to a second live
    /// transcriber. Feeding the live view only the system tap meant that while
    /// the user spoke, with nothing else playing, it saw silence - and filled
    /// that silence with invented sentences.
    private func startMic() {
        guard let micIn = startTranscriber(label: "You:") else { return }
        let p = Process()
        p.executableURL = Paths.captureHelper
        p.arguments = ["mic", Paths.recordings
            .appendingPathComponent(micName).path, "--stream"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Recorder.helperLog(wavName, tag: "mic")
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            try? micIn.write(contentsOf: d)
        }
        try? p.run()
        micProc = p
    }

    // MARK: - Plumbing

    private func meter(_ peak: Float) {
        // fast attack so a syllable registers, slow release so the bar reads
        level = peak > level ? peak : level * 0.82 + peak * 0.18
    }

    /// live.py owns the LocalAgreement-2 stabilisation. We feed it the same PCM
    /// we are writing to disk so only one tap is ever open.
    private func startTranscriber(label: String = "") -> FileHandle? {
        guard FileManager.default.fileExists(atPath: Paths.livePy.path) else { return nil }
        let python = URL(fileURLWithPath: Paths.python)
        let p = Process()
        p.executableURL = python
        var a = ["-B", Paths.livePy.path, "--stdin", "--provisional"]
        if !label.isEmpty { a.append("--label=" + label) }
        p.arguments = a
        p.currentDirectoryURL = Paths.root
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            Task { @MainActor [weak self] in self?.absorb(d) }
        }
        do { try p.run() } catch { return nil }
        transcriber = p
        return stdin.fileHandleForWriting
    }

    /// live.py emits one committed segment per line; a line starting with "~"
    /// is the unstable tail and replaces whatever tail we were showing.
    private func absorb(_ data: Data) {
        lineBuf.append(data)
        while let nl = lineBuf.firstIndex(of: 0x0A) {
            let line = String(decoding: lineBuf[..<nl], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            lineBuf.removeSubrange(...nl)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("~") {
                provisional = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else {
                committed.append(line)
                provisional = ""
            }
        }
    }

    /// Seeds the window with real mixed-direction text so the RTL layout can be
    /// eyeballed without a live meeting. ponytail: test hook, not a feature.
    func seedDemo() {
        committed = [
            "אוקיי, אז בואו נסכם את מה שדיברנו עליו בסשן הקודם.",
            "צריך לעשות deploy לפרודקשן עד יום חמישי.",
            "The SIEM integration is blocked on the CrowdStrike API key.",
            "אמרתי לאורנה שה-SLA שלנו הוא ארבע שעות, לא עשרים וארבע.",
        ]
        provisional = "ואז נצטרך לבדוק את ה-latency של"
        level = 0.42
    }
}
