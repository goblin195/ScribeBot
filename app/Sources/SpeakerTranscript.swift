import Foundation

struct SpeakerSegment: Codable, Identifiable, Sendable, Equatable {
    var id: String
    var source: String
    var speaker: String
    var start: Double
    var end: Double
    var text: String
    var rawText: String
}

struct SpeakerTranscript: Codable, Sendable, Equatable {
    var version: Int
    var revision: String
    var segments: [SpeakerSegment]
    var names: [String: String]
    var remoteSpeakerCount: Int
    var warnings: [String]
    var engine: String? = nil

    func validate() throws {
        guard version == 1, (0...100).contains(remoteSpeakerCount), Set(segments.map(\.id)).count == segments.count,
              segments.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start
                  && ["system", "microphone"].contains($0.source) && names[$0.speaker] != nil }),
              names.values.allSatisfy({ !$0.isEmpty && !$0.contains("\n") && !$0.contains("\r") }) else {
            throw RecordingFailure(message: "Invalid speaker transcript returned by the decoder.")
        }
    }

    var lines: [String] {
        segments.map { segment in
            let seconds = Int(segment.start)
            let time = String(format: "%02d:%02d", seconds / 60, seconds % 60)
            return "[\(time)] \(names[segment.speaker] ?? "Uncertain speaker"): \(segment.text)"
        }
    }

    static func analyze(_ rec: Recording, directory: URL, root: URL,
                        python: String, remoteSpeakers: Int = 0) throws -> SpeakerTranscript {
        let localPython = root.appendingPathComponent(".venv/bin/python").path
        let executable = FileManager.default.isExecutableFile(atPath: localPython) ? localPython : python
        let script = root.appendingPathComponent("speaker_transcript.py")
        let system = directory.appendingPathComponent(rec.wav)
        let microphone = directory.appendingPathComponent(rec.id + "-you.wav")
        let text = try SavedTranscription.run(audio: system, python: executable,
            script: script, root: root, recovering: false, timeout: 1800,
            arguments: [system.path, microphone.path, "--remote-speakers", String(remoteSpeakers)])
        let result = try JSONDecoder().decode(SpeakerTranscript.self, from: Data(text.utf8))
        try result.validate()
        return result
    }
}
