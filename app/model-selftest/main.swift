// Exercises ModelSetup.swift against a local HTTP server. Not part of the app
// bundle — build.sh only globs Sources/*.swift. bench/model_download.py compiles
// this, starts the server and runs it; ./check runs that.
//
//   swiftc app/Sources/ModelSetup.swift app/model-selftest/main.swift -o /tmp/mcheck
//   /tmp/mcheck http://127.0.0.1:8000 /tmp/work
//
// The point is that the paths which can leave a broken file where the decoder
// will find it are run for real, on a few megabytes instead of 1.5 GB: an HTML
// error page served with a 200, a body whose length is not the model's, a wrong
// checksum, a cancel halfway, and a resume that the server answers with 206 or
// ignores entirely.
import Foundation
import CryptoKit

let args = CommandLine.arguments
guard args.count == 3, let base = URL(string: args[1]) else {
    print("usage: mcheck <base-url> <work-dir>"); exit(2)
}
let work = URL(fileURLWithPath: args[2])
var failures = 0

func check(_ ok: Bool, _ what: String) {
    if !ok { print("FAIL: \(what)"); failures += 1 }
}

/// Pumps the main run loop, which is what drains the DispatchQueue.main hops
/// the downloader publishes its state through.
func wait(_ seconds: Double = 30, until done: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if done() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return done()
}

func sha256(_ url: URL) -> String {
    var hasher = SHA256()
    hasher.update(data: (try? Data(contentsOf: url)) ?? Data())
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func fresh(_ name: String) -> (ModelDownloads, URL) {
    let dir = work.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: dir)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return (ModelDownloads(directory: dir), dir)
}

func spec(_ path: String, id: String, bytes: Int64, sha: String) -> ModelSpec {
    ModelSpec(id: id, label: id, blurb: "",
              url: base.appendingPathComponent(path), bytes: bytes, sha256: sha)
}

func size(_ url: URL) -> Int64 {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
}

func failureText(_ s: ModelState?) -> String? {
    if case let .failed(why) = s { return why }
    return nil
}

// The server writes what it is serving here so the two sides cannot drift.
let facts = try! JSONDecoder().decode(
    [String: String].self,
    from: Data(contentsOf: base.appendingPathComponent("facts.json")))
let goodBytes = Int64(facts["good.size"]!)!
let goodSHA = facts["good.sha256"]!
let slowBytes = Int64(facts["slow.size"]!)!
let slowSHA = facts["slow.sha256"]!

// ---------------------------------------------------------------- happy path
do {
    let (dl, dir) = fresh("happy")
    let s = spec("good.bin", id: "good.bin", bytes: goodBytes, sha: goodSHA)
    dl.refresh([s])
    check(dl.state["good.bin"] == .absent, "an empty directory reads as absent")

    var seen: [(Int64, Int64)] = []
    dl.start(s)
    let finished = wait {
        if case let .downloading(r, t) = dl.state["good.bin"] ?? .absent,
           seen.last?.0 != r { seen.append((r, t)) }
        return dl.state["good.bin"] == .installed || failureText(dl.state["good.bin"]) != nil
    }
    check(finished, "the download finished")
    check(dl.state["good.bin"] == .installed,
          "installed, not \(String(describing: dl.state["good.bin"]))")

    // Real progress: several observations, never going backwards, in bytes.
    check(seen.count >= 3, "saw \(seen.count) progress updates, wanted at least 3")
    check(zip(seen, seen.dropFirst()).allSatisfy { $0.0 <= $1.0 }, "progress is monotonic")
    check(seen.allSatisfy { $0.1 == goodBytes }, "progress reports the real total")
    check(seen.first.map { $0.0 < goodBytes } ?? false, "progress starts below the total")

    let final = dir.appendingPathComponent("good.bin")
    check(size(final) == goodBytes, "the installed file is the whole file")
    check(sha256(final) == goodSHA, "the installed file hashes to the published digest")
    check(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("good.bin.part").path),
          "no .part left behind")
    check(dl.installedURL(s) == final, "installedURL finds it")

    // A relaunch must not re-download it: state is read back off the disk.
    let again = ModelDownloads(directory: dir)
    again.refresh([s])
    check(again.state["good.bin"] == .installed, "a fresh instance sees the finished download")
}

// --------------------------------------------- an HTML error page with a 200
do {
    let (dl, dir) = fresh("html")
    let s = spec("error.html", id: "html.bin", bytes: goodBytes, sha: goodSHA)
    dl.start(s)
    _ = wait { failureText(dl.state["html.bin"]) != nil }
    let why = failureText(dl.state["html.bin"])
    check(why != nil, "an HTML page is refused, not installed")
    check(why?.contains("html") ?? false, "the message names what arrived: \(why ?? "nil")")
    check(size(dir.appendingPathComponent("html.bin")) == 0, "nothing installed")
    check(size(dir.appendingPathComponent("html.bin.part")) == 0, "no .part left")
}

// ------------------------------------------------------------------- HTTP 404
do {
    let (dl, _) = fresh("missing")
    let s = spec("nope.bin", id: "nope.bin", bytes: goodBytes, sha: goodSHA)
    dl.start(s)
    _ = wait { failureText(dl.state["nope.bin"]) != nil }
    check(failureText(dl.state["nope.bin"])?.contains("404") ?? false,
          "a 404 is reported as a 404: \(failureText(dl.state["nope.bin"]) ?? "nil")")
}

// ------------------------------------------- a body that is not the right size
do {
    let (dl, dir) = fresh("short")
    // The catalog says the model is a megabyte longer than what is served. This
    // is the truncated-download guard, and it fires before anything is written.
    let s = spec("good.bin", id: "short.bin", bytes: goodBytes + 1_048_576, sha: goodSHA)
    dl.start(s)
    _ = wait { failureText(dl.state["short.bin"]) != nil }
    check(failureText(dl.state["short.bin"])?.contains("bytes") ?? false,
          "a wrong length is refused: \(failureText(dl.state["short.bin"]) ?? "nil")")
    check(size(dir.appendingPathComponent("short.bin")) == 0, "nothing installed")
}

// ------------------------------------------------------------ wrong checksum
do {
    let (dl, dir) = fresh("checksum")
    let s = spec("good.bin", id: "bad.bin", bytes: goodBytes,
                 sha: String(repeating: "0", count: 64))
    dl.start(s)
    _ = wait { failureText(dl.state["bad.bin"]) != nil }
    check(failureText(dl.state["bad.bin"])?.contains("checksum") ?? false,
          "a wrong checksum is refused: \(failureText(dl.state["bad.bin"]) ?? "nil")")
    check(size(dir.appendingPathComponent("bad.bin")) == 0, "nothing installed")
    check(size(dir.appendingPathComponent("bad.bin.part")) == 0,
          "the rejected .part is removed rather than left to be resumed forever")
}

// --------------------------------------------------------- cancel, then resume
do {
    let (dl, dir) = fresh("resume")
    let s = spec("slow.bin", id: "slow.bin", bytes: slowBytes, sha: slowSHA)
    dl.start(s)
    var cancelled = false
    _ = wait {
        if !cancelled, case let .downloading(r, _) = dl.state["slow.bin"] ?? .absent, r > 0 {
            dl.cancel(s); cancelled = true
        }
        if case .partial = dl.state["slow.bin"] ?? .absent { return true }
        return failureText(dl.state["slow.bin"]) != nil
    }
    guard case let .partial(stopped) = dl.state["slow.bin"] ?? .absent else {
        check(false, "cancel leaves a resumable partial, got \(String(describing: dl.state["slow.bin"]))")
        exit(failures == 0 ? 0 : 1)
    }
    let part = dir.appendingPathComponent("slow.bin.part")
    check(stopped > 0 && stopped < slowBytes, "cancelled partway: \(stopped) of \(slowBytes)")
    check(size(part) == stopped, "the .part on disk is what the state reports")
    check(size(dir.appendingPathComponent("slow.bin")) == 0,
          "a cancelled download installs nothing")

    // Resuming asks for a byte range and appends to what is already there.
    dl.start(s)
    _ = wait(60) { dl.state["slow.bin"] == .installed || failureText(dl.state["slow.bin"]) != nil }
    check(dl.state["slow.bin"] == .installed,
          "resumed to installed, not \(String(describing: dl.state["slow.bin"]))")
    let final = dir.appendingPathComponent("slow.bin")
    check(size(final) == slowBytes, "the resumed file is complete")
    check(sha256(final) == slowSHA, "the resumed file is byte-for-byte correct")
    check(!FileManager.default.fileExists(atPath: part.path), "the .part is gone")
}

// ------------------------------------------ a server that ignores Range headers
do {
    let (dl, dir) = fresh("norange")
    let s = spec("norange/good.bin", id: "nr.bin", bytes: goodBytes, sha: goodSHA)
    // Garbage standing in for a partial download the server will not honour.
    let part = dir.appendingPathComponent("nr.bin.part")
    FileManager.default.createFile(atPath: part.path,
                                   contents: Data(repeating: 0xEE, count: 500_000))
    dl.refresh([s])
    check(dl.state["nr.bin"] == .partial(500_000), "a leftover .part reads as resumable")
    dl.start(s)
    _ = wait(60) { dl.state["nr.bin"] == .installed || failureText(dl.state["nr.bin"]) != nil }
    check(dl.state["nr.bin"] == .installed,
          "a 200 answer to a Range request restarts cleanly, not \(String(describing: dl.state["nr.bin"]))")
    // If the 500 KB of 0xEE had been appended to, this is what would catch it.
    check(sha256(dir.appendingPathComponent("nr.bin")) == goodSHA,
          "the file is the model, not the model with garbage in front of it")
}

// ---------------------------------------------------------- Content-Range parse
check(ModelDownloads.parseContentRange("bytes 100-999/1000")! == (100, 1000), "content-range parsed")
check(ModelDownloads.parseContentRange("bytes 0-0/1")! == (0, 1), "content-range single byte")
check(ModelDownloads.parseContentRange("bytes */1000") == nil, "unsatisfiable range rejected")
check(ModelDownloads.parseContentRange("nonsense") == nil, "junk range rejected")

// -------------------------------------------- the catalog names what languages.py wants
check(ModelCatalog.hebrew.id == "ivrit-large-v3-turbo.bin", "hebrew filename matches languages.py")
check(ModelCatalog.multilingual.id == "vanilla-large-v3-turbo.bin",
      "multilingual filename matches languages.py")
check(ModelCatalog.all.allSatisfy { $0.sha256.count == 64 }, "every catalog entry has a sha256")
check(ModelCatalog.all.allSatisfy { $0.url.scheme == "https" }, "every catalog URL is https")
check(ModelCatalog.directory(under: URL(fileURLWithPath: "/x")).path == "/x/models",
      "the download directory mirrors languages.support_dir()/models")

if failures == 0 { print("model download self-check passed") }
exit(failures == 0 ? 0 : 1)
