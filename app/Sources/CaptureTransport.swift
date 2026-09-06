import Foundation
import Darwin

/// Preview is expendable; the recording is not. Never wait for a decoder to
/// read its pipe. On overload stop this preview rather than splice audio across
/// a missing interval (the preview protocol has no timestamp-gap message).
final class PreviewInput: @unchecked Sendable {
    // All handle access and mutable state are protected by lock.
    private let handle: FileHandle
    private let lock = NSLock()
    private var closed = false
    private var pending = Data()
    private let capacity = 8 * 16_000 * 2 // eight seconds of PCM16 mono

    init(_ handle: FileHandle) throws {
        self.handle = handle
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    /// False exactly once if the decoder stops accepting audio.
    func send(_ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return true }
        guard pending.count + data.count <= capacity else {
            closeLocked()
            return false
        }
        pending.append(data)
        // Capture continually supplies buffers. Retry pending bytes on each
        // arrival, absorbing normal decode bursts without blocking the reader.
        var written = 0
        let healthy = pending.withUnsafeBytes { bytes -> Bool in
            var offset = 0
            defer { written = offset }
            while offset < bytes.count {
                let n = Darwin.write(handle.fileDescriptor,
                                     bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n > 0 { offset += n }
                else if n < 0 && errno == EINTR { continue }
                else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return true }
                else { return false }
            }
            return true
        }
        pending.removeFirst(written)
        if !healthy { closeLocked() }
        return healthy
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        closeLocked()
    }

    private func closeLocked() {
        guard !closed else { return }
        closed = true
        pending = Data()
        try? handle.close()
    }

    deinit { close() }
}

/// Each source needs its own byte framing, including split UTF-8 characters.
struct PreviewLines {
    private var buffer = Data()

    mutating func append(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[..<nl], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            buffer.removeSubrange(...nl)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }
}

/// A dedicated reader drains the capture pipe even when preview is paused.
/// Stop waits for EOF before closing the WAV, preserving the last audio buffer.
final class CaptureReader: Sendable {
    private let done = DispatchGroup()

    init(_ handle: FileHandle, consume: @escaping @Sendable (Data) -> Void) {
        done.enter()
        DispatchQueue.global(qos: .userInitiated).async { [done] in
            defer { try? handle.close(); done.leave() }
            while true {
                let data = handle.availableData
                if data.isEmpty { return }
                consume(data)
            }
        }
    }

    func wait(seconds: Double = 5) -> Bool {
        done.wait(timeout: .now() + seconds) == .success
    }
}
