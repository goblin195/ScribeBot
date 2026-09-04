// Export goes through export.py rather than re-implementing SRT here: that
// script already owns the timestamp rounding and the speaker-merge rules, and
// it has a self-check. We hand it segments and a destination.
import SwiftUI
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case md, srt, json
    var id: String { rawValue }
    var label: String {
        switch self {
        case .md: return "Markdown"
        case .srt: return "SRT subtitles"
        case .json: return "JSON segments"
        }
    }
    var ext: String { rawValue }
}

enum TranscriptExport {
    /// Returns nil on success, or a message worth showing.
    @MainActor
    static func run(_ format: ExportFormat, lines: [TranscriptLine],
                    duration: TimeInterval, name: String,
                    wav: URL? = nil) async -> String? {
        guard !lines.isEmpty else { return "Nothing to export." }
        let script = Paths.root.appendingPathComponent("export.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            return "export.py is missing (expected at \(script.path))."
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(safe(name)).\(format.ext)"
        panel.allowedContentTypes = [UTType(filenameExtension: format.ext) ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return nil }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribebot-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            // Real decoder timestamps when the audio is still there; the
            // length-proportional estimate only as a fallback.
            if let wav, let real = Transcript.realSegments(wav: wav,
                                                  scribebotPy: Paths.scribebotPy,
                                                  root: Paths.root) {
                try JSONSerialization.data(withJSONObject: real,
                                           options: [.prettyPrinted, .withoutEscapingSlashes])
                    .write(to: tmp)
            } else {
                try Transcript.segmentsJSON(lines, duration: duration).write(to: tmp)
            }
        } catch {
            return "Could not build the segment list: \(error.localizedDescription)"
        }

        let err = await Task.detached(priority: .userInitiated) {
            shell(script: script, args: [tmp.path, "--format", format.rawValue,
                                         "-o", dest.path])
        }.value
        if let err { return err }
        NSWorkspace.shared.activateFileViewerSelecting([dest])
        return nil
    }

    /// A filename that survives a Hebrew meeting title and a colon in a date.
    private static func safe(_ s: String) -> String {
        let cleaned = s.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "transcript" : String(cleaned.prefix(80))
    }

    private static func shell(script: URL, args: [String]) -> String? {
        let venv = Paths.root.appendingPathComponent(".venv/bin/python3")
        let python = FileManager.default.isExecutableFile(atPath: venv.path)
            ? venv : URL(fileURLWithPath: "/usr/bin/python3")
        let p = Process()
        p.executableURL = python
        p.arguments = [script.path] + args
        p.currentDirectoryURL = Paths.root
        let e = Pipe()
        p.standardError = e
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch {
            return "cannot run python3: \(error.localizedDescription)"
        }
        let data = e.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus != 0 else { return nil }
        let msg = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return msg.isEmpty ? "export.py exited with code \(p.terminationStatus)." : msg
    }
}
