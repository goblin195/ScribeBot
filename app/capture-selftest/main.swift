import Foundation
import SwiftUI
import EventKit

// Compile the production Recorder with an isolated library and fake helper
// paths. No test can resolve the real user's Application Support directory.
enum Paths {
    static let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SCRIBEBOT_CAPTURE_TEST_ROOT"]!)
    static let recordings = root.appendingPathComponent("recordings")
    static let captureHelper = root.appendingPathComponent("capture")
    static let livePy = root.appendingPathComponent("live.py")
    static let scribebotPy = root.appendingPathComponent("scribebot.py")
    static let python = ProcessInfo.processInfo.environment["SCRIBEBOT_CAPTURE_TEST_PYTHON"]!
}

@MainActor final class Library: ObservableObject {
    var saved: Recording?
    var lines: [String] = []
    func save(_ rec: Recording, transcript: [String]? = nil) throws {
        if let transcript { try RecordingFiles.writeTranscript(rec, lines: transcript, directory: Paths.recordings) }
        try RecordingFiles.save(rec, directory: Paths.recordings)
        saved = rec
        reload()
    }
    func reload() {
        if let id = saved?.id { saved = try! RecordingFiles.load(id, directory: Paths.recordings) }
        if let rec = saved { lines = transcript(rec).components(separatedBy: "\n") }
    }
    func transcript(_ rec: Recording) -> String {
        (try? String(contentsOf: Paths.recordings.appendingPathComponent(rec.id + ".txt"), encoding: .utf8)) ?? ""
    }
}

func calendarTitle(at: Date, store: EKEventStore) -> String? { nil }

final class Bytes: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ value: Data) { lock.lock(); defer { lock.unlock() }; data.append(value) }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}

@main struct CaptureCheck {
    @MainActor static func main() async throws {
        // Healthy audio reaches the reader byte-for-byte.
        let pipe = Pipe()
        let input = try PreviewInput(pipe.fileHandleForWriting)
        let bytes = Data([1, 2, 3, 4])
        precondition(input.send(bytes))
        precondition(pipe.fileHandleForReading.readData(ofLength: 4) == bytes)
        input.close()

        // A decoder that never reads must not hold up the caller.
        let stalled = Pipe()
        let blocked = try PreviewInput(stalled.fileHandleForWriting)
        let before = Date()
        precondition(!blocked.send(Data(count: 4 * 1024 * 1024)))
        precondition(Date().timeIntervalSince(before) < 1)
        precondition(blocked.send(bytes), "Only one overload notification")

        // A dead decoder must not kill the app with SIGPIPE.
        let dead = Pipe()
        let gone = try PreviewInput(dead.fileHandleForWriting)
        try dead.fileHandleForReading.close()
        precondition(!gone.send(bytes))

        // Independent source framing handles UTF-8 split between callbacks.
        var them = PreviewLines(), you = PreviewLines()
        let hebrew = Data("Them: שלום\n".utf8)
        precondition(them.append(hebrew.prefix(8)).isEmpty)
        precondition(you.append(Data("You: hello\n".utf8)) == ["You: hello"])
        precondition(them.append(hebrew.dropFirst(8)) == ["Them: שלום"])

        // Stop drains the tail through EOF, not just until the child exits.
        let capture = Pipe(), received = Bytes()
        let reader = CaptureReader(capture.fileHandleForReading) { received.append($0) }
        let payload = Data(repeating: 7, count: 1_048_576)
        try capture.fileHandleForWriting.write(contentsOf: payload)
        try capture.fileHandleForWriting.close()
        precondition(reader.wait())
        precondition(received.value == payload)

        // An inherited lease survives its parent handle, then releases on child
        // exit. This prevents retry while an orphaned helper still owns audio.
        var owner: RecordingLease? = try RecordingLease(directory: Paths.recordings)
        let child = Process()
        child.executableURL = Paths.captureHelper
        child.arguments = ["stream"]
        child.standardInput = try owner!.captureInput()
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        try (child.standardInput as! FileHandle).close()
        owner = nil
        do {
            _ = try RecordingLease(directory: Paths.recordings)
            preconditionFailure("Capture child must retain the library lease")
        } catch {}
        child.terminate()
        child.waitUntilExit()
        do { let released = try RecordingLease(directory: Paths.recordings); withExtendedLifetime(released) {} }

        let library = Library(), secondLibrary = Library()
        let recorder = Recorder(library: secondLibrary)
        // Separate instance below lets us inspect the production finalization path.
        let recording = Recorder(library: library)
        recording.start()
        precondition(recording.isRecording)
        let initial = try RecordingFiles.load(library.saved!.id, directory: Paths.recordings)
        precondition(initial.status == .recording, "Manifest must exist before stop")
        do {
            _ = try RecordingLease(directory: Paths.recordings)
            preconditionFailure("Another owner must not acquire an active library")
        } catch {}
        try await Task.sleep(for: .seconds(1))
        precondition(recording.lastError?.contains("preview paused") == true)
        recording.stop()
        precondition(recording.isFinalizing)
        recording.start()
        precondition(!recording.isRecording, "Cannot restart while draining/finalizing")
        let deadline = Date().addingTimeInterval(15)
        while recording.isFinalizing && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        precondition(!recording.isFinalizing, "Stop/finalize must finish")
        precondition(library.lines == ["Them: verified saved audio", "You: verified saved audio"],
                     "Both WAV headers must be finalized before transcription: \(library.lines)")
        let rec = library.saved!
        precondition(rec.status == .complete)
        for name in [rec.wav, rec.wav.replacingOccurrences(of: ".wav", with: "-you.wav")] {
            let size = try FileManager.default.attributesOfItem(
                atPath: Paths.recordings.appendingPathComponent(name).path)[.size] as! NSNumber
            precondition(size.intValue >= 1_048_576 + 44, "Slow preview lost saved audio")
        }


        // A new Recorder can retry a persisted interrupted job. Use the real
        // recovery module through the synthetic decoder and retain source bytes.
        var interrupted = rec
        interrupted.status = .transcribing
        try RecordingFiles.save(interrupted, directory: Paths.recordings)
        let originalAudio = try Data(contentsOf: Paths.recordings.appendingPathComponent(rec.wav))
        let originalTranscript = library.transcript(rec)
        try Data().write(to: Paths.root.appendingPathComponent("fail-mic"))
        let relaunched = Recorder(library: library)
        relaunched.retry(interrupted)
        let retryDeadline = Date().addingTimeInterval(15)
        while relaunched.isFinalizing && Date() < retryDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        precondition(!relaunched.isFinalizing)
        precondition(library.saved?.status == .partial)
        precondition(library.transcript(rec) == originalTranscript, "Partial retry must keep previous text")
        precondition(FileManager.default.fileExists(atPath: Paths.recordings.appendingPathComponent(rec.id + ".partial.txt").path))
        let retainedAudio = try Data(contentsOf: Paths.recordings.appendingPathComponent(rec.wav))
        precondition(retainedAudio == originalAudio)
        try FileManager.default.removeItem(at: Paths.root.appendingPathComponent("fail-mic"))
        relaunched.retry(library.saved!)
        let finishDeadline = Date().addingTimeInterval(15)
        while relaunched.isFinalizing && Date() < finishDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        precondition(!relaunched.isFinalizing && library.saved?.status == .complete)

        // Persistence failure is observable and does not replace existing text.
        let blocker = Paths.recordings.appendingPathComponent(rec.id + ".partial.txt")
        try FileManager.default.removeItem(at: blocker)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: false)
        do {
            _ = try RecordingFiles.commit(rec, lines: ["replacement"], errors: ["mic failed"], directory: Paths.recordings)
            preconditionFailure("Invalid output destination must throw")
        } catch {}
        precondition(library.transcript(rec) == originalTranscript)
        try FileManager.default.removeItem(at: blocker)
        do {
            try RecordingFiles.requireSpace(directory: Paths.recordings, minimum: Int64.max)
            preconditionFailure("Low-space check must refuse the job")
        } catch {}
        // Legacy metadata is readable without a status or a migration write.
        let legacy = "{\"id\":\"old\",\"title\":\"Old\",\"startedAt\":\"2026-09-05T00:00:00Z\",\"duration\":1,\"wav\":\"old.wav\"}"
        try Data(legacy.utf8).write(to: Paths.recordings.appendingPathComponent("old.json"))
        let old = try RecordingFiles.load("old", directory: Paths.recordings)
        precondition(old.status == nil)

        // Speaker data survives relaunch, renders every source in chronology,
        // and is preserved with the previous transcript after a decode failure.
        let speakerData = SpeakerTranscript(version: 1, revision: "test-revision",
            segments: [SpeakerSegment(id: "remote", source: "system", speaker: "remote-1",
                start: 1, end: 2, text: "hello", rawText: "hello"),
                SpeakerSegment(id: "local", source: "microphone", speaker: "local",
                start: 2, end: 3, text: "שלום", rawText: "שלום")],
            names: ["remote-1": "Amir", "local": "You"], remoteSpeakerCount: 1, warnings: [])
        let labeled = try RecordingFiles.commit(old, lines: speakerData.lines, errors: [],
            directory: Paths.recordings, speakers: speakerData)
        let reloadedSpeakers = try RecordingFiles.load("old", directory: Paths.recordings)
        precondition(reloadedSpeakers.speakerTranscript == speakerData)
        let preserved = try RecordingFiles.commit(labeled, lines: [], errors: ["decode failed"], directory: Paths.recordings)
        precondition(preserved.speakerTranscript == speakerData)
        let preservedText = try String(contentsOf: Paths.recordings.appendingPathComponent("old.txt"), encoding: .utf8)
        precondition(preservedText.contains("Amir"))

        // Missing preview script must not prevent either audio capture path.
        try FileManager.default.moveItem(at: Paths.livePy, to: Paths.root.appendingPathComponent("live.off"))
        recorder.start()
        precondition(recorder.isRecording)
        precondition(recorder.lastError?.contains("live.py is missing") == true)
        try await Task.sleep(for: .milliseconds(500))
        recorder.stop()
        let secondDeadline = Date().addingTimeInterval(15)
        while recorder.isFinalizing && Date() < secondDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        precondition(!recorder.isFinalizing)
        precondition(secondLibrary.lines == ["Them: verified saved audio", "You: verified saved audio"])

        // A launch failure after previews start must clean up without trapping
        // the UI in finalizing or opening a second concurrent recording.
        try FileManager.default.moveItem(at: Paths.root.appendingPathComponent("live.off"), to: Paths.livePy)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: Paths.captureHelper.path)
        recorder.start()
        precondition(!recorder.isRecording)
        let failedDeadline = Date().addingTimeInterval(10)
        while recorder.isFinalizing && Date() < failedDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        precondition(!recorder.isFinalizing)
        precondition(recorder.lastError?.contains("capture failed") == true)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Paths.captureHelper.path)
        try Data().write(to: Paths.root.appendingPathComponent("exit-tap"))
        recorder.start()
        let exitDeadline = Date().addingTimeInterval(15)
        while (recorder.isRecording || recorder.isFinalizing) && Date() < exitDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        precondition(!recorder.isRecording && !recorder.isFinalizing)
        precondition(secondLibrary.saved?.captureIssue?.contains("stopped unexpectedly") == true)
        precondition(secondLibrary.saved?.status != .complete)
        print("capture transport self-check passed (synthetic helper audio, no hardware)")
    }
}
