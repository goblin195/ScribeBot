import Foundation

enum SavedTranscription {
    /// Output files avoid a stdout/stderr pipe deadlock. They live in a private
    /// temporary directory, never alongside the user's irreplaceable WAVs.
    static func run(audio: URL, python: String, script: URL, root: URL,
                    recovering: Bool, timeout: TimeInterval = 600, arguments: [String]? = nil) throws -> String {
        let values = try audio.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw RecordingFailure(message: "Audio must be a regular file, not a link.")
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribebot-transcribe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let out = temporary.appendingPathComponent("stdout.txt")
        let err = temporary.appendingPathComponent("stderr.txt")
        try Data().write(to: out)
        try Data().write(to: err)
        let output = try FileHandle(forWritingTo: out), error = try FileHandle(forWritingTo: err)
        defer { try? output.close(); try? error.close() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-B", script.path] + (arguments ?? (["file", audio.path] + (recovering ? ["--recover"] : [])))
        p.currentDirectoryURL = root
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = output
        p.standardError = error
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if p.isRunning {
            p.terminate()
            let grace = Date().addingTimeInterval(2)
            while p.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            throw RecordingFailure(message: "Transcription timed out. Saved audio and the previous transcript have been kept.")
        }
        guard p.terminationStatus == 0 else {
            let detail = try String(contentsOf: err, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw RecordingFailure(message: "Transcription exited with \(p.terminationStatus): \(String(detail.suffix(600)))")
        }
        return try String(contentsOf: out, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
