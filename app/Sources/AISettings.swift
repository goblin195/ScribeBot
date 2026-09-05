// Which engine writes summaries, and with which model.
//
// The list is not hardcoded here: providers.py knows what is installed on this
// machine and `summarize.py --list-providers` reports it. The picker can then
// only offer what will actually run, and Ollama's model list is the one Ollama
// really has rather than a guess written months ago.
import SwiftUI

struct AIProvider: Identifiable, Decodable, Equatable {
    var id: String
    var label: String
    var available: Bool
    var models: [String]
    var detail: String
    var path: String
    /// True when choosing this sends the transcript off this Mac. The project
    /// promises it does not, so the picker has to say when that stops holding.
    var sendsDataOffDevice: Bool
}

private struct ProviderStatus: Decodable {
    var providers: [AIProvider]
    var `default`: String
    var defaultOllamaModel: String
}

@MainActor
final class AISettings: ObservableObject {
    static let shared = AISettings()

    @Published private(set) var providers: [AIProvider] = []
    @Published private(set) var probing = false
    /// Why the list is empty, when it is. A blank silent picker reads as a
    /// broken app rather than as "Ollama isn't running".
    @Published private(set) var problem: String?
    /// What providers.py considers Ollama's default. Used when the user has
    /// never chosen: picking merely the newest-pulled model would silently
    /// change which model summarises their meetings.
    @Published private(set) var defaultOllamaModel = "gemma4:latest"

    private init() {}

    // MARK: - Choice

    static var providerID: String {
        get { UserDefaults.standard.string(forKey: "summaryProvider") ?? "ollama" }
        set { UserDefaults.standard.set(newValue, forKey: "summaryProvider") }
    }

    /// Empty means "whatever that provider defaults to", which is right for
    /// Claude and Codex: they each have their own configured model, and handing
    /// them an Ollama model name is an error - "gemma4:latest" reached
    /// `claude --model` once and it rejected the run.
    static func model(for provider: String) -> String {
        UserDefaults.standard.string(forKey: "summaryModel.\(provider)") ?? ""
    }

    static func setModel(_ model: String, for provider: String) {
        UserDefaults.standard.set(model, forKey: "summaryModel.\(provider)")
    }

    var current: AIProvider? { providers.first { $0.id == Self.providerID } }
    var sendsDataOffDevice: Bool { current?.sendsDataOffDevice ?? false }

    // MARK: - Probe

    func refresh() {
        guard !probing else { return }
        probing = true
        problem = nil
        let script = Paths.root.appendingPathComponent("summarize.py")
        Task.detached(priority: .userInitiated) {
            let result = Self.probe(script: script)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.probing = false
                switch result {
                case let .success(status):
                    self.providers = status.providers
                    self.defaultOllamaModel = status.defaultOllamaModel
                    // A stored choice for something no longer installed would
                    // fail at summarise time with no clue why.
                    if !status.providers.contains(where: { $0.id == Self.providerID }) {
                        Self.providerID = status.default
                    }
                case let .failure(message):
                    self.problem = message
                }
            }
        }
    }

    private enum Probe { case success(ProviderStatus), failure(String) }

    private nonisolated static func probe(script: URL) -> Probe {
        guard FileManager.default.fileExists(atPath: script.path) else {
            return .failure("summarize.py is missing at \(script.path)")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Paths.python)
        p.arguments = ["-B", script.path, "--list-providers"]
        p.currentDirectoryURL = Paths.root
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch {
            return .failure("cannot run python3: \(error.localizedDescription)")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        // Never read an empty result as "no providers" - that is the silent
        // failure this project keeps relearning.
        guard p.terminationStatus == 0 else {
            let text = String(decoding: errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(text.isEmpty
                            ? "summarize.py exited with \(p.terminationStatus)"
                            : String(text.prefix(300)))
        }
        do {
            return .success(try JSONDecoder().decode(ProviderStatus.self, from: data))
        } catch {
            return .failure("could not read the provider list: \(error.localizedDescription)")
        }
    }
}
