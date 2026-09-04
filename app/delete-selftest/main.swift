import Foundation

func check(_ condition: Bool, _ message: String) {
    if !condition { fatalError(message) }
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let names = ["call.wav", "call-you.wav", "call.txt", "call.summary.md", "call.json", "other.wav"]
for option in RecordingDeletion.allCases {
    let dir = root.appendingPathComponent(option.rawValue)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    for name in names { try Data("fixture".utf8).write(to: dir.appendingPathComponent(name)) }
    var moved: [String] = []
    try option.perform(id: "call", wav: "call.wav", directory: dir) { url in
        moved.append(url.lastPathComponent)
        try fm.removeItem(at: url)
    }
    let expected: Set<String> = option == .audio ? ["call.wav", "call-you.wav"] :
        option == .transcript ? ["call.txt", "call.summary.md"] : Set(names.dropLast())
    check(Set(moved) == expected, "Wrong files for \(option)")
    check(fm.fileExists(atPath: dir.appendingPathComponent("other.wav").path), "Other call changed")
    // Missing files should allow a retry after a partial failure.
    try option.perform(id: "call", wav: "call.wav", directory: dir) { _ in fatalError("Moved a missing file") }
}
do {
    _ = try RecordingDeletion.both.files(id: "../escape", wav: "../escape.wav", directory: root)
    fatalError("Traversal accepted")
} catch {}
let failure = root.appendingPathComponent("failure")
try fm.createDirectory(at: failure, withIntermediateDirectories: true)
for name in names { try Data().write(to: failure.appendingPathComponent(name)) }
do {
    try RecordingDeletion.both.perform(id: "call", wav: "call.wav", directory: failure) { _ in
        throw NSError(domain: "Test", code: 1)
    }
    fatalError("Failure swallowed")
} catch {}
check(fm.fileExists(atPath: failure.appendingPathComponent("call.json").path), "Metadata removed after failure")
print("Deletion checks passed: choices, missing files, unrelated calls, traversal, and failure propagation")
