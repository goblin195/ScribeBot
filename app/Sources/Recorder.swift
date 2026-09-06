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
private final class PCMSink: @unchecked Sendable {
    // Writes/close are locked; duration is read only after the drain and close.
    private let wav: FileHandle
    private var bytes = 0
    private let lock = NSLock()
    private var closed = false

    private var failed = false
    private var checkpointBytes = 0

    init(wavURL: URL) throws {
        let fd = Darwin.open(wavURL.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        wav = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try wav.write(contentsOf: PCMSink.header(0))
    }

    /// Returns the peak amplitude (0...1) of this chunk.
    func write(_ data: Data) throws -> Float {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !failed else { return 0 }
        do {
            try wav.write(contentsOf: data)
            bytes += data.count
            if bytes - checkpointBytes >= 5 * 32_000 {
                try wav.seek(toOffset: 0)
                try wav.write(contentsOf: PCMSink.header(bytes))
                try wav.seekToEnd()
                try wav.synchronize()
                checkpointBytes = bytes
            }
        } catch { failed = true; throw error }
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
    func close(padTo seconds: Double = 0) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        defer { try? wav.close() }
        deliveredSeconds = Double(bytes) / (16_000 * 2)
        let want = Int(seconds * 16_000) * 2
        if want > bytes {
            var left = want - bytes
            while left > 0 {
                let n = min(left, 32_000)
                try wav.write(contentsOf: Data(count: n))
                left -= n
            }
            bytes = want
        }
        try wav.seek(toOffset: 0)
        try wav.write(contentsOf: PCMSink.header(bytes))
        try wav.synchronize()
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
    private var lineBuffers: [String: PreviewLines] = [:]
    private var tails: [String: String] = [:]
    private var previewInputs: [String: PreviewInput] = [:]
    private var tapReader: CaptureReader?
    private var micReader: CaptureReader?
    private var session = UUID()
    private var pausedSources: Set<String> = []
    @Published private(set) var activeID: String?
    private var activeRecord: Recording?
    private var lease: RecordingLease?
    private var checkpointAt: TimeInterval = 0

    let library: Library
    private let eventStore = EKEventStore()

    init(library: Library) { self.library = library }

    // MARK: - Lifecycle

    func start() {
        guard !isRecording, !isFinalizing else { return }
        guard FileManager.default.fileExists(atPath: Paths.captureHelper.path) else {
            lastError = "capture helper missing at \(Paths.captureHelper.path)"; return
        }
        session = UUID()
        pausedSources = []
        lineBuffers = [:]; tails = [:]
        committed = []; provisional = ""; elapsed = 0; lastError = nil
        let id = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString.prefix(8)
        wavName = "\(id).wav"
        startedAt = Date()

        let started = startedAt!
        let calendarEnabled = UserDefaults.standard.object(forKey: "useCalendarTitles") as? Bool ?? true
        let title = (calendarEnabled ? calendarTitle(at: started, store: eventStore) : nil)
            ?? started.formatted(date: .abbreviated, time: .shortened)
        let rec = Recording(id: id, title: title, startedAt: started, duration: 0,
                            wav: wavName, status: .recording, updatedAt: started)
        let sink: PCMSink
        do {
            lease = try RecordingLease(directory: Paths.recordings)
            try RecordingFiles.requireSpace(directory: Paths.recordings)
            try library.save(rec)
            activeRecord = rec; activeID = rec.id; checkpointAt = 0
            sink = try PCMSink(wavURL: Paths.recordings.appendingPathComponent(wavName))
        } catch {
            failActive("Cannot start recording: \(error.localizedDescription)")
            return
        }
        let transcriberIn = startTranscriber(label: "Them:")
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
        let run = session
        monitorCapture(p, source: "System audio", run: run)
        do {
            p.standardError = try Recorder.helperLog(wavName, tag: "tap")
            p.standardInput = try lease?.captureInput()
            try p.run()
            try? (p.standardInput as? FileHandle)?.close()
        } catch {
            try? (p.standardInput as? FileHandle)?.close()
            lastError = "capture failed: \(error.localizedDescription)"
            stopPreviews()
            let mic = micProc, reader = micReader
            self.micProc = nil; self.micReader = nil
            if mic?.isRunning == true { mic?.terminate() }
            self.sink = nil; startedAt = nil
            isFinalizing = true
            DispatchQueue.global(qos: .userInitiated).async {
                _ = Self.waitForCapture(mic)
                _ = reader?.wait()
                let closeFailure: String?
                do { try sink.close(); closeFailure = nil }
                catch { closeFailure = error.localizedDescription }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.failActive((self.lastError ?? "Capture startup failed") + (closeFailure.map { "; " + $0 } ?? ""))
                }
            }
            return
        }
        // Close the parent's writer so the reader sees EOF when the helper exits.
        try? out.fileHandleForWriting.close()
        tapReader = CaptureReader(out.fileHandleForReading) { [weak self] data in
            let peak: Float
            do { peak = try sink.write(data) }
            catch {
                Task { @MainActor [weak self] in
                    guard let self, self.session == run, self.isRecording else { return }
                    self.captureFailed("Cannot save system audio: \(error.localizedDescription)")
                }
                return
            }
            let previewOK = transcriberIn?.send(data) ?? true
            Task { @MainActor [weak self] in
                guard let self, self.session == run, self.isRecording else { return }
                self.meter(peak)
                if !previewOK { self.pausePreview("Them:") }
            }
        }
        tap = p
        isRecording = true
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let t = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(t)
                if self.elapsed - self.checkpointAt >= 5 {
                    self.checkpointAt = self.elapsed
                    self.checkpoint()
                }
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        isFinalizing = true
        ticker?.invalidate(); ticker = nil
        elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? elapsed
        let seconds = elapsed
        let tap = self.tap, micProc = self.micProc
        let tapReader = self.tapReader, micReader = self.micReader
        let sink = self.sink
        self.tap = nil; self.micProc = nil
        self.tapReader = nil; self.micReader = nil; self.sink = nil
        stopPreviews()
        level = 0; provisional = ""
        if tap?.isRunning == true { tap?.terminate() }
        if micProc?.isRunning == true { micProc?.terminate() }
        DispatchQueue.global(qos: .userInitiated).async {
            // The mic helper closes AVAudioFile in its SIGTERM handler. Reading
            // it before exit can mistake an unfinished WAV header for silence.
            let tapExited = Self.waitForCapture(tap)
            let micExited = Self.waitForCapture(micProc)
            let tapDrained = tapReader?.wait() ?? true
            let micDrained = micReader?.wait() ?? true
            let closeError: String?
            do { try sink?.close(padTo: seconds); closeError = nil }
            catch { closeError = error.localizedDescription }
            let delivered = sink?.deliveredSeconds ?? 0
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !tapExited || !micExited || !tapDrained || !micDrained {
                    if self.activeRecord?.captureIssue == nil {
                        self.activeRecord?.captureIssue = "Capture did not stop cleanly. Audio may be incomplete; see the capture log."
                    }
                }
                if let closeError { self.activeRecord?.captureIssue = "Cannot finish saving audio: " + closeError }
                self.finishStop(seconds: seconds, delivered: delivered)
            }
        }
    }

    private nonisolated static func waitForCapture(_ process: Process?) -> Bool {
        guard let process else { return true }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        guard !process.isRunning else {
            kill(process.processIdentifier, SIGKILL)
            let killedDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < killedDeadline { Thread.sleep(forTimeInterval: 0.02) }
            return false
        }
        return process.terminationStatus == 0 ||
            (process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGTERM)
    }

    private func finishStop(seconds: Double, delivered: Double) {
        guard var rec = activeRecord else { isFinalizing = false; lease = nil; return }
        rec.duration = seconds
        rec.updatedAt = Date()
        rec.status = .awaitingTranscription
        startedAt = nil
        // Byte delivery alone cannot distinguish intentional silence from loss;
        // do not claim that missing speech is known from this ratio.
        if seconds >= 5, delivered < seconds * 0.8, rec.captureIssue == nil {
            rec.captureIssue = "System audio delivered fewer samples than the recording duration. Check the capture log and audio for gaps."
        }
        activeRecord = rec
        do { try library.save(rec, transcript: committed) }
        catch { failActive("Cannot save recording state: \(error.localizedDescription)"); return }
        finalize(rec)
    }

    private func checkpoint() {
        guard var rec = activeRecord, isRecording else { return }
        rec.duration = elapsed; rec.updatedAt = Date()
        do {
            try RecordingFiles.requireSpace(directory: Paths.recordings, minimum: 32 * 1024 * 1024)
            try library.save(rec)
            activeRecord = rec
        } catch { captureFailed("Recording checkpoint failed: \(error.localizedDescription)") }
    }

    private func captureFailed(_ message: String) {
        activeRecord?.captureIssue = message
        lastError = message
        stop()
    }

    private func monitorCapture(_ process: Process, source: String, run: UUID) {
        var env = ProcessInfo.processInfo.environment
        env["SCRIBEBOT_OWNER_PID"] = String(getpid())
        process.environment = env
        process.terminationHandler = { [weak self] p in
            Task { @MainActor [weak self] in
                guard let self, self.session == run, self.isRecording else { return }
                self.captureFailed("\(source) stopped unexpectedly (exit \(p.terminationStatus)). Saved audio has been kept.")
            }
        }
    }

    private func failActive(_ message: String) {
        var detail = message
        if var rec = activeRecord {
            rec.status = .failed; rec.failure = message; rec.updatedAt = Date()
            do { try library.save(rec) }
            catch { detail += "\nCould not persist failure state: \(error.localizedDescription)" }
        }
        lastError = detail
        activeRecord = nil; activeID = nil; startedAt = nil
        isFinalizing = false; lease = nil
    }

    /// Explicit retry only. Audio is read through temporary repaired copies,
    /// never overwritten, and the library lease rejects still-active helpers.
    func retry(_ recording: Recording) {
        guard !isRecording, !isFinalizing else { return }
        do {
            lease = try RecordingLease(directory: Paths.recordings)
            try RecordingFiles.requireSpace(directory: Paths.recordings)
            var rec = try RecordingFiles.load(recording.id, directory: Paths.recordings)
            guard rec.status?.needsRecovery == true else {
                throw RecordingFailure(message: "This recording does not have an interrupted or failed job to retry.")
            }
            // A recording interrupted before stop has an unknown captured tail.
            if rec.status == .recording {
                rec.captureIssue = rec.captureIssue ?? "Recovered audio from an interrupted recording. Check its ending for missing speech."
            }
            session = UUID(); lastError = nil
            activeRecord = rec; activeID = rec.id
            finalize(rec, recovering: true)
        } catch {
            lease = nil
            lastError = "Cannot retry: \(error.localizedDescription)"
        }
    }

    private var micName: String { wavName.replacingOccurrences(of: ".wav", with: "-you.wav") }

    func identifySpeakers(_ recording: Recording, remoteSpeakers: Int) {
        guard !isRecording, !isFinalizing else { return }
        do {
            lease = try RecordingLease(directory: Paths.recordings)
            let rec = try RecordingFiles.load(recording.id, directory: Paths.recordings)
            guard rec.status == nil || rec.status == .complete || rec.status == .partial else {
                throw RecordingFailure(message: "Finish or retry transcription before separating speakers.")
            }
            try RecordingFiles.requireSpace(directory: Paths.recordings)
            activeID = rec.id; isFinalizing = true; lastError = nil
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let speakers = try SpeakerTranscript.analyze(rec, directory: Paths.recordings,
                        root: Paths.root, python: Paths.python, remoteSpeakers: remoteSpeakers)
                    _ = try RecordingFiles.commit(rec, lines: speakers.lines, errors: [],
                        directory: Paths.recordings, speakers: speakers)
                    DispatchQueue.main.async { [weak self] in
                        self?.library.reload()
                        self?.activeID = nil; self?.isFinalizing = false; self?.lease = nil
                    }
                } catch {
                    var failed = rec
                    failed.speakerFailure = error.localizedDescription
                    do { try RecordingFiles.save(failed, directory: Paths.recordings) }
                    catch { failed.speakerFailure = "Speaker analysis and saving its error failed: \(error.localizedDescription)" }
                    let message = failed.speakerFailure
                    DispatchQueue.main.async { [weak self] in
                        self?.library.reload(); self?.lastError = message
                        self?.activeID = nil; self?.isFinalizing = false; self?.lease = nil
                    }
                }
            }
        } catch { lease = nil; lastError = error.localizedDescription }
    }

    private func finalize(_ recording: Recording, recovering: Bool = false) {
        var rec = recording
        rec.status = .transcribing; rec.failure = nil; rec.updatedAt = Date()
        do { try library.save(rec) }
        catch { failActive("Cannot start transcription: \(error.localizedDescription)"); return }
        isFinalizing = true
        let job = rec
        DispatchQueue.global(qos: .userInitiated).async {
            var lines: [String] = [], errors: [String] = []
            for (label, filename) in [("Them", job.wav), ("You", job.id + "-you.wav")] {
                do {
                    let text = try SavedTranscription.run(
                        audio: Paths.recordings.appendingPathComponent(filename),
                        python: Paths.python, script: Paths.scribebotPy,
                        root: Paths.root, recovering: recovering)
                    if !text.isEmpty { lines.append(label + ": " + text) }
                } catch { errors.append(label + ": " + error.localizedDescription) }
            }
            // commit writes the transcript before completion metadata, before
            // hopping to the UI. A failure leaves previous text intact.
            do {
                var result = try RecordingFiles.commit(job, lines: lines, errors: errors, directory: Paths.recordings)
                if errors.isEmpty, FileManager.default.fileExists(atPath: Paths.root.appendingPathComponent("speaker_transcript.py").path) {
                    do {
                        let speakers = try SpeakerTranscript.analyze(result, directory: Paths.recordings,
                            root: Paths.root, python: Paths.python)
                        result = try RecordingFiles.commit(result, lines: speakers.lines, errors: [],
                            directory: Paths.recordings, speakers: speakers)
                    } catch {
                        result.speakerFailure = "Speaker separation unavailable: \(error.localizedDescription)"
                        try RecordingFiles.save(result, directory: Paths.recordings)
                    }
                }
                let finished = result
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.library.reload()
                    self.committed = self.library.transcript(finished).components(separatedBy: "\n")
                    self.lastError = finished.failure ?? finished.speakerFailure
                    self.activeRecord = nil; self.activeID = nil
                    self.isFinalizing = false; self.lease = nil
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.failActive("Cannot save transcription: \(error.localizedDescription)")
                }
            }
        }
    }

    /// stderr for one of the capture helpers, appended to a log beside the
    /// recording. This used to be FileHandle.nullDevice, and that single line
    /// is why three shipped bugs were invisible: the helper prints its input
    /// device, its clock source, every sample rate, the Bluetooth low-quality
    /// warning, each tap stall, and every hard failure - and all of it was
    /// thrown away, so a broken recording and a good one looked identical.
    nonisolated static func helperLog(_ wavName: String, tag: String) throws -> FileHandle {
        let id = wavName.replacingOccurrences(of: ".wav", with: "")
        let url = Paths.recordings.appendingPathComponent("\(id).capture.log")
        let fd = Darwin.open(url.path, O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        try h.write(contentsOf: Data("\n===== \(tag) \(stamp) =====\n".utf8))
        return h
    }

    /// Capture the local voice to its own file AND feed it to a second live
    /// transcriber. Feeding the live view only the system tap meant that while
    /// the user spoke, with nothing else playing, it saw silence - and filled
    /// that silence with invented sentences.
    private func startMic() {
        let micIn = startTranscriber(label: "You:")
        let p = Process()
        p.executableURL = Paths.captureHelper
        p.arguments = ["mic", Paths.recordings
            .appendingPathComponent(micName).path, "--stream"]
        let out = Pipe()
        p.standardOutput = out
        let run = session
        monitorCapture(p, source: "Microphone", run: run)
        do {
            p.standardError = try Recorder.helperLog(wavName, tag: "mic")
            p.standardInput = try lease?.captureInput()
            try p.run()
            try? (p.standardInput as? FileHandle)?.close()
        } catch {
            try? (p.standardInput as? FileHandle)?.close()
            lastError = "Microphone capture failed: \(error.localizedDescription)"
            activeRecord?.captureIssue = lastError
            previewInputs["You:"]?.close()
            if micTranscriber?.isRunning == true { micTranscriber?.terminate() }
            micTranscriber = nil
            return
        }
        try? out.fileHandleForWriting.close()
        micReader = CaptureReader(out.fileHandleForReading) { [weak self] data in
            if micIn?.send(data) == false {
                Task { @MainActor [weak self] in
                    guard let self, self.session == run, self.isRecording else { return }
                    self.pausePreview("You:")
                }
            }
        }
        micProc = p
    }

    // MARK: - Plumbing

    private func meter(_ peak: Float) {
        // fast attack so a syllable registers, slow release so the bar reads
        level = peak > level ? peak : level * 0.82 + peak * 0.18
    }

    /// live.py owns the LocalAgreement-2 stabilisation. We feed it the same PCM
    /// we are writing to disk so only one tap is ever open.
    private func startTranscriber(label: String) -> PreviewInput? {
        guard FileManager.default.fileExists(atPath: Paths.livePy.path) else {
            lastError = "Live preview unavailable: live.py is missing. Audio will still be saved."
            return nil
        }
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
        // live.py's stderr used to go to nullDevice. With no model on disk -
        // the state of every fresh install until the first-run download
        // finishes - the decoder failed on every chunk and the live view
        // stayed blank for a whole meeting with the reason thrown away.
        let run = session
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self, self.session == run, self.isRecording,
                      !self.pausedSources.contains(label) else { return }
                self.absorb(d, source: label)
            }
        }
        do {
            p.standardError = try Recorder.helperLog(wavName, tag: "live " + label)
            let input = try PreviewInput(stdin.fileHandleForWriting)
            try p.run()
            try? stdin.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            if label == "You:" { micTranscriber = p } else { transcriber = p }
            previewInputs[label] = input
            return input
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            lastError = "\(label) live preview unavailable: \(error.localizedDescription). Audio will still be saved."
            return nil
        }
    }

    private func pausePreview(_ source: String) {
        pausedSources.insert(source)
        previewInputs[source]?.close()
        let process = source == "You:" ? micTranscriber : transcriber
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if process?.isRunning == true { process?.terminate() }
        tails[source] = nil
        provisional = [tails["Them:"], tails["You:"]].compactMap { $0 }.joined(separator: "\n")
        lastError = "\(source) live preview paused because the decoder stopped keeping up. Audio is still being saved for final transcription."
    }

    private func stopPreviews() {
        for input in previewInputs.values { input.close() }
        previewInputs = [:]
        for process in [transcriber, micTranscriber] {
            (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            if process?.isRunning == true { process?.terminate() }
        }
        transcriber = nil; micTranscriber = nil
        tails = [:]
    }

    private func absorb(_ data: Data, source: String) {
        for line in lineBuffers[source, default: PreviewLines()].append(data) {
            if line.hasPrefix("~") {
                tails[source] = source + " " + line.dropFirst().trimmingCharacters(in: .whitespaces)
            } else {
                committed.append(line)
                tails[source] = nil
            }
        }
        provisional = [tails["Them:"], tails["You:"]].compactMap { $0 }.joined(separator: "\n")
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
