// scribebot audio capture spike — CoreAudio process taps (macOS 14.2+)
// Captures per-process system audio with no virtual audio driver.
import Foundation
import CoreAudio
import AVFoundation

// MARK: - CoreAudio property helpers

func addr(_ selector: AudioObjectPropertySelector,
          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
-> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                               mElement: kAudioObjectPropertyElementMain)
}

func getData<T>(_ objID: AudioObjectID, _ a: AudioObjectPropertyAddress, _ def: T) -> T? {
    var size = UInt32(MemoryLayout<T>.size)
    var value = def
    var a = a
    let st = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(objID, &a, 0, nil, &size, $0)
    }
    return st == noErr ? value : nil
}

func getArray<T>(_ objID: AudioObjectID, _ a: AudioObjectPropertyAddress, _ def: T) -> [T] {
    var a = a
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(objID, &a, 0, nil, &size) == noErr, size > 0
    else { return [] }
    let count = Int(size) / MemoryLayout<T>.size
    var out = [T](repeating: def, count: count)
    let st = out.withUnsafeMutableBufferPointer {
        AudioObjectGetPropertyData(objID, &a, 0, nil, &size, $0.baseAddress!)
    }
    return st == noErr ? out : []
}

func getString(_ objID: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var a = addr(sel)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var cf: CFString? = nil
    let st = withUnsafeMutablePointer(to: &cf) {
        AudioObjectGetPropertyData(objID, &a, 0, nil, &size, $0)
    }
    guard st == noErr, let cf else { return nil }
    return cf as String
}

// MARK: - Process enumeration

struct AudioProc {
    let objID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let name: String
    let playing: Bool
}

func audioProcesses() -> [AudioProc] {
    let ids = getArray(AudioObjectID(kAudioObjectSystemObject),
                       addr(kAudioHardwarePropertyProcessObjectList), AudioObjectID(0))
    return ids.compactMap { id in
        let pid = getData(id, addr(kAudioProcessPropertyPID), pid_t(0)) ?? -1
        let bundle = getString(id, kAudioProcessPropertyBundleID) ?? ""
        let out = getData(id, addr(kAudioProcessPropertyIsRunningOutput), UInt32(0)) ?? 0
        guard pid > 0 else { return nil }
        let name = (try? procName(pid)) ?? bundle
        return AudioProc(objID: id, pid: pid, bundleID: bundle,
                         name: name, playing: out != 0)
    }
}

func procName(_ pid: pid_t) throws -> String {
    var buf = [CChar](repeating: 0, count: 4096)
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    guard n > 0 else { return "" }
    return URL(fileURLWithPath: String(cString: buf)).lastPathComponent
}

func defaultInputDeviceName() -> String? {
    guard let devID: AudioDeviceID = getData(AudioObjectID(kAudioObjectSystemObject),
            addr(kAudioHardwarePropertyDefaultInputDevice), AudioDeviceID(0)),
          devID != 0 else { return nil }
    return getString(devID, kAudioObjectPropertyName)
}

func defaultInputDeviceUID() -> String? {
    guard let devID: AudioDeviceID = getData(AudioObjectID(kAudioObjectSystemObject),
            addr(kAudioHardwarePropertyDefaultInputDevice), AudioDeviceID(0)),
          devID != 0 else { return nil }
    return getString(devID, kAudioDevicePropertyDeviceUID)
}

func defaultOutputDeviceUID() -> String? {
    guard let devID: AudioDeviceID = getData(AudioObjectID(kAudioObjectSystemObject),
            addr(kAudioHardwarePropertyDefaultSystemOutputDevice), AudioDeviceID(0)),
          devID != 0 else { return nil }
    return getString(devID, kAudioDevicePropertyDeviceUID)
}

/// Microphone capture on its own engine.
///
/// The microphone deliberately does NOT go through the tap's aggregate device.
/// A tap-bearing aggregate only runs IO while something is playing, so with the
/// far side silent the callback never fires and the local speaker is dropped -
/// which made the app appear deaf when someone simply talked to it. An
/// independent engine keeps ticking regardless of what the rest of the Mac is
/// doing, and its samples are summed with the tap downstream.
final class MicCapture {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let outFmt: AVAudioFormat

    init?(sampleRate: Double) {
        guard let f = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                    sampleRate: sampleRate, channels: 1,
                                    interleaved: false) else { return nil }
        outFmt = f
    }

    func start(_ onAudio: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let input = engine.inputNode
        // Read the hardware format AFTER prepare(). Queried before, the input
        // node can report a stale rate - observed reporting 16 kHz while
        // CoreAudio said the device was at 48 kHz, after another recorder had
        // held the microphone. The converter was then built from a format the
        // hardware was not using and silently produced nothing.
        engine.prepare()
        // Acoustic echo cancellation. Without it the far side of the call
        // arrives twice - once from the tap and again as speaker bleed picked
        // up by the microphone - and the doubled signal measurably degrades
        // transcription ("הלטנסי של האפי" came back as "אלתן שיא של יפי").
        // Echo cancellation is OFF by default, opt in with SCRIBEBOT_AEC=1.
        // It does keep the far side out of the local track, but macOS voice
        // processing also DUCKS system output - measured, the tap's peak fell
        // from 0.54 to 0.018 with it on, so cleaning up the microphone quietly
        // wrecked the far-side recording. On speakers the "you" track will
        // contain some echo; on headphones, which is how meetings are usually
        // taken, there is nothing to cancel.
        if ProcessInfo.processInfo.environment["SCRIBEBOT_AEC"] == "1" {
            do {
                try input.setVoiceProcessingEnabled(true)
                FileHandle.standardError.write(
                    "\u{2192} echo cancellation on\n".data(using: .utf8)!)
            } catch {
                FileHandle.standardError.write(
                    "\u{2192} echo cancellation unavailable: \(error.localizedDescription)\n"
                        .data(using: .utf8)!)
            }
        }
        // installTap must be given the node's OUTPUT format - the format the
        // tap will deliver. inputFormat describes the hardware side and using
        // it here stops the tap firing at all.
        let inFmt = input.outputFormat(forBus: 0)
        guard inFmt.sampleRate > 0, inFmt.channelCount > 0 else {
            throw Err("no microphone input available (format \(inFmt))")
        }
        // Name the device and flag the low-bandwidth Bluetooth profile. A pair
        // of earbuds becoming the default input drops the rate from 48 kHz to
        // 16 kHz and the level with it - recordings go quiet for a reason that
        // has nothing to do with this app, and silence about it reads as a bug.
        let devName = defaultInputDeviceName() ?? "unknown input"
        var fmtLine = "\u{2192} microphone: \(devName) at \(Int(inFmt.sampleRate)) Hz"
        if inFmt.sampleRate <= 16_000 {
            fmtLine += "  [LOW QUALITY - this looks like a Bluetooth hands-free"
            fmtLine += " profile; switch input to the built-in microphone for"
            fmtLine += " better transcription]"
        }
        FileHandle.standardError.write((fmtLine + "\n").data(using: .utf8)!)
        converter = AVAudioConverter(from: inFmt, to: outFmt)
        input.installTap(onBus: 0, bufferSize: 1024, format: inFmt) { [weak self] buf, _ in
            guard let self, let conv = self.converter else { return }
            let ratio = self.outFmt.sampleRate / buf.format.sampleRate
            let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: self.outFmt, frameCapacity: cap)
            else { return }
            var err: NSError?
            var supplied = false
            conv.convert(to: out, error: &err) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return buf
            }
            if err == nil && out.frameLength > 0 { onAudio(out) }
        }
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

// MARK: - Tap + aggregate device

func captureMonoFormat(aggregateRate: Double) throws -> AVAudioFormat {
    guard aggregateRate.isFinite, aggregateRate >= 8_000, aggregateRate <= 384_000,
          let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                    sampleRate: aggregateRate, channels: 1,
                                    interleaved: false) else {
        throw Err("invalid aggregate input sample rate: \(aggregateRate)")
    }
    return format
}

func checkCaptureRates() throws {
    // Synthetic duration/pitch regression; this does not exercise hardware.
    // The old 48 kHz label on 16 kHz frames produced one third the duration.
    for rate in [16_000.0, 24_000.0, 44_100.0, 48_000.0] {
        let input = try captureMonoFormat(aggregateRate: rate)
        let output = try captureMonoFormat(aggregateRate: 16_000)
        let frames = AVAudioFrameCount(rate * 3)
        let source = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: frames)!
        source.frameLength = frames
        for i in 0..<Int(frames) {
            source.floatChannelData![0][i] = Float(sin(2 * .pi * 440 * Double(i) / rate)) * 0.25
        }
        let result = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 49_024)!
        let converter = AVAudioConverter(from: input, to: output)!
        var supplied = false
        var error: NSError?
        converter.convert(to: result, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return source
        }
        guard error == nil, abs(Int(result.frameLength) - 48_000) < 128 else {
            throw Err("sample rate regression: \(rate) Hz produced \(result.frameLength) frames")
        }
        let samples = result.floatChannelData![0]
        let crossings = (1..<Int(result.frameLength)).filter { samples[$0 - 1] < 0 && samples[$0] >= 0 }.count
        guard abs(crossings - 1320) < 5 else { throw Err("pitch changed at \(rate) Hz") }
    }
    do {
        _ = try captureMonoFormat(aggregateRate: 0)
        throw Err("zero sample rate accepted")
    } catch let error as Err where error.msg.hasPrefix("invalid aggregate") {}
    print("capture rate self-check passed (synthetic duration and pitch, no hardware)")
}

final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var rateListener: AudioObjectPropertyListenerBlock?
    private let ioQueue = DispatchQueue(label: "dev.scribebot.tap.io", qos: .userInitiated)
    private(set) var format: AVAudioFormat?
    private(set) var micUIDUsed: String?

    /// targets: process object IDs to capture. Empty = whole system (global tap).
    /// When `withMic` is set the default input device joins the same aggregate,
    /// so the microphone and the system tap share one clock and arrive in one
    /// IOProc callback. Without it a recording contains everyone except the
    /// person holding the Mac, which is half of any meeting.
    ///
    /// Known limitation: a tap-bearing aggregate only runs IO while something
    /// is playing, whatever is nominated as the clock. In total silence the
    /// callback does not fire at all, so a stretch where ONLY the local person
    /// speaks and no application produces sound is not captured. In a real call
    /// the far side supplies near-continuous audio, so this bites mainly when
    /// talking to a muted room. Fixing it properly needs a second, independent
    /// input-only device rather than one shared aggregate.
    func start(targets: [AudioObjectID],
               onAudio: @escaping (AVAudioPCMBuffer, AudioTimeStamp) -> Void) throws {
        let desc: CATapDescription = targets.isEmpty
            ? CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            : CATapDescription(stereoMixdownOfProcesses: targets)
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted      // keep audio audible to the user

        FileHandle.standardError.write("→ creating process tap (targets=\(targets.count))...\n".data(using:.utf8)!)
        var st = AudioHardwareCreateProcessTap(desc, &tapID)
        FileHandle.standardError.write("→ tap created: st=\(st) id=\(tapID)\n".data(using:.utf8)!)
        guard st == noErr, tapID != kAudioObjectUnknown else {
            throw Err("AudioHardwareCreateProcessTap failed: \(st) \(fourCC(st))")
        }

        // Ask the tap what format it will hand us.
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var fa = addr(kAudioTapPropertyFormat)
        FileHandle.standardError.write("→ querying tap format...\n".data(using:.utf8)!)
        st = AudioObjectGetPropertyData(tapID, &fa, 0, nil, &size, &asbd)
        guard st == noErr, let fmt = AVAudioFormat(streamDescription: &asbd) else {
            throw Err("kAudioTapPropertyFormat failed: \(st)")
        }
        format = fmt

        // Wrap the tap in a private aggregate device so we can pull an IOProc off it.
        let aggUID = UUID().uuidString
        guard let outUID = defaultOutputDeviceUID() else {
            throw Err("no default system output device")
        }
        let clockUID = outUID
        let subDevices: [[String: Any]] = [[kAudioSubDeviceUIDKey as String: outUID]]
        let cfg: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "scribebot-agg",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            // The output device clocks this aggregate. Its rate can differ
            // from the process tap's advertised format with Bluetooth HFP.
            kAudioAggregateDeviceMainSubDeviceKey as String: clockUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: subDevices,
            kAudioAggregateDeviceTapListKey as String: [[
                kAudioSubTapUIDKey as String: desc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey as String: true,
            ]],
        ]
        FileHandle.standardError.write("\u{2192} clock source: \(clockUID)\n".data(using:.utf8)!)
        st = AudioHardwareCreateAggregateDevice(cfg as CFDictionary, &aggID)
        guard st == noErr, aggID != kAudioObjectUnknown else {
            throw Err("AudioHardwareCreateAggregateDevice failed: \(st)")
        }

        FileHandle.standardError.write("→ agg created, installing IOProc...\n".data(using:.utf8)!)
        // IOProc receives frames on the aggregate's clock, not the tap's
        // advertised rate. CMF Bluetooth HFP delivered 16 kHz while the tap
        // reported 48 kHz: using the latter compressed a 135 s call to 45 s.
        guard let inputRate: Float64 = getData(aggID,
                addr(kAudioDevicePropertyNominalSampleRate), Float64(0)) else {
            throw Err("cannot read aggregate input sample rate")
        }
        let monoFmt = try captureMonoFormat(aggregateRate: inputRate)
        FileHandle.standardError.write(Data("→ tap format: \(fmt.sampleRate) Hz; aggregate input: \(inputRate) Hz\n".utf8))
        self.format = monoFmt

        // A route change must not silently continue with the old converter.
        // Recorder surfaces this nonzero exit and preserves both saved tracks.
        var rateAddress = addr(kAudioDevicePropertyNominalSampleRate)
        let aggregate = aggID
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            let current: Float64? = getData(aggregate,
                addr(kAudioDevicePropertyNominalSampleRate), Float64(0))
            guard current != inputRate else { return }
            FileHandle.standardError.write(Data("ERROR: audio device sample rate changed; restart recording with the selected audio device.\n".utf8))
            DispatchQueue.main.async { exit(1) }
        }
        st = AudioObjectAddPropertyListenerBlock(aggID, &rateAddress, ioQueue, listener)
        guard st == noErr else { throw Err("cannot monitor aggregate sample rate: \(st)") }
        rateListener = listener

        st = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, ioQueue) {
            _, inInputData, inInputTime, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            var frames = 0
            for b in abl {
                let ch = max(1, Int(b.mNumberChannels))
                frames = max(frames, Int(b.mDataByteSize) / 4 / ch)
            }
            guard frames > 0,
                  let out = AVAudioPCMBuffer(pcmFormat: monoFmt,
                                             frameCapacity: AVAudioFrameCount(frames)),
                  let dst = out.floatChannelData?[0] else { return }
            out.frameLength = AVAudioFrameCount(frames)
            for i in 0..<frames { dst[i] = 0 }
            for b in abl {
                guard let raw = b.mData else { continue }
                let ch = max(1, Int(b.mNumberChannels))
                let n = min(frames, Int(b.mDataByteSize) / 4 / ch)
                let src = raw.assumingMemoryBound(to: Float.self)
                for i in 0..<n {
                    var acc: Float = 0
                    for c in 0..<ch { acc += src[i * ch + c] }
                    dst[i] += acc / Float(ch)
                }
            }
            onAudio(out, inInputTime.pointee)
        }
        guard st == noErr, let procID else {
            throw Err("AudioDeviceCreateIOProcIDWithBlock failed: \(st)")
        }
        FileHandle.standardError.write("→ starting device...\n".data(using:.utf8)!)
        st = AudioDeviceStart(aggID, procID)
        guard st == noErr else { throw Err("AudioDeviceStart failed: \(st)") }
        FileHandle.standardError.write("→ RUNNING\n".data(using:.utf8)!)

    }

    func stop() {
        if let rateListener {
            var a = addr(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(aggID, &a, ioQueue, rateListener)
            self.rateListener = nil
        }
        if let procID {
            AudioDeviceStop(aggID, procID)
            AudioDeviceDestroyIOProcID(aggID, procID)
        }
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
    }
}

struct Err: LocalizedError {
    let msg: String
    init(_ m: String) { msg = m }
    var errorDescription: String? { msg }
}

func fourCC(_ st: OSStatus) -> String {
    let v = UInt32(bitPattern: st)
    let b = [UInt8((v >> 24) & 255), UInt8((v >> 16) & 255),
             UInt8((v >> 8) & 255), UInt8(v & 255)]
    let s = String(bytes: b, encoding: .ascii) ?? ""
    return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " } ? "'\(s)'" : ""
}

/// Sums the tap and the microphone into one mono stream.
///
/// The microphone drives the clock: it ticks steadily no matter what the rest of
/// the Mac is doing, whereas the tap only produces callbacks while something is
/// playing. Driving from the mic means a stretch where only the local person
/// speaks is still captured. Tap audio that arrives between mic ticks waits in a
/// queue and is summed into the next one; if none arrived, silence is summed,
/// which is simply the local voice on its own.
final class Mixer {
    private let lock = NSLock()
    private var tapQueue: [Float] = []
    private let onOutput: (AVAudioPCMBuffer) -> Void
    private let fmt: AVAudioFormat

    init(format: AVAudioFormat, onOutput: @escaping (AVAudioPCMBuffer) -> Void) {
        self.fmt = format
        self.onOutput = onOutput
    }

    func pushTap(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData?[0] else { return }
        let n = Int(buf.frameLength)
        lock.lock()
        tapQueue.append(contentsOf: UnsafeBufferPointer(start: ch, count: n))
        // never let the queue grow without bound if the mic stalls
        if tapQueue.count > Int(fmt.sampleRate) * 5 {
            tapQueue.removeFirst(tapQueue.count - Int(fmt.sampleRate) * 5)
        }
        lock.unlock()
    }

    func pushMic(_ buf: AVAudioPCMBuffer) {
        guard let mic = buf.floatChannelData?[0] else { return }
        let n = Int(buf.frameLength)
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)),
              let dst = out.floatChannelData?[0] else { return }
        out.frameLength = AVAudioFrameCount(n)
        lock.lock()
        // Headroom: two full-scale sources summed will clip, and a clipped
        // waveform transcribes badly. Scale both and soft-limit the result.
        let take = min(n, tapQueue.count)
        for i in 0..<take {
            let v = mic[i] * 0.8 + tapQueue[i] * 0.8
            dst[i] = v > 1 ? 1 : (v < -1 ? -1 : v)
        }
        for i in take..<n { dst[i] = mic[i] }
        if take > 0 { tapQueue.removeFirst(take) }
        lock.unlock()
        onOutput(out)
    }
}

// MARK: - Permission

private let tccHandle: UnsafeMutableRawPointer? =
    dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
private typealias RequestFn   = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void
private let kAudioCaptureService = "kTCCServiceAudioCapture" as CFString

/// 0 = authorized, 1 = denied, 2 = unknown/not-determined, -1 = SPI missing
func audioCapturePreflight() -> Int {
    guard let h = tccHandle, let sym = dlsym(h, "TCCAccessPreflight") else { return -1 }
    return unsafeBitCast(sym, to: PreflightFn.self)(kAudioCaptureService, nil)
}

func ensureAudioPermission() {
    func log(_ m: String) { FileHandle.standardError.write("\u{2192} \(m)\n".data(using:.utf8)!) }
    let pre = audioCapturePreflight()
    log("kTCCServiceAudioCapture preflight: \(pre)  (0=authorized 1=denied 2=undetermined)")
    guard pre != 0 else { return }
    guard let h = tccHandle, let sym = dlsym(h, "TCCAccessRequest") else {
        log("TCC SPI unavailable"); return
    }
    log("requesting system audio recording permission - APPROVE THE DIALOG")
    var done = false, granted = false
    unsafeBitCast(sym, to: RequestFn.self)(kAudioCaptureService, nil) { ok in
        granted = ok; done = true
    }
    let deadline = Date().addingTimeInterval(90)
    while !done && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.2))
    }
    log(done ? "permission result: granted=\(granted)" : "prompt timed out")
}

// MARK: - CLI

let args = CommandLine.arguments

func cmdList() {
    let procs = audioProcesses().sorted { ($0.playing ? 0 : 1, $0.name) < ($1.playing ? 0 : 1, $1.name) }
    print(String(format: "%-6s %-8s %-34s %s", ("OBJID" as NSString).utf8String!,
                 ("PID" as NSString).utf8String!, ("NAME" as NSString).utf8String!,
                 ("BUNDLE" as NSString).utf8String!))
    for p in procs {
        let mark = p.playing ? "▶" : " "
        print(String(format: "%-6u %-8d %@%-33@ %@", p.objID, p.pid, mark,
                     p.name as NSString, p.bundleID as NSString))
    }
}

/// Record the tap and the microphone to SEPARATE files.
///
/// Summing them into one mono channel is what made transcription worse than
/// tap-only: even with echo cancellation the two sources interfere, and the
/// decoder has to pick a sentence out of the blend. Kept apart, each is
/// transcribed at full quality - and which side spoke is then known for free,
/// without any diarization at all.
/// Microphone only, to a file. Runs alongside a separate `stream` process that
/// handles system audio, so the two never mix.
/// `stream` decides whether the PCM is also written to stdout. The live view
/// was fed the system tap only, so while the user spoke and nothing else played
/// it saw pure silence - and the decoder filled that silence with invented
/// sentences. The local voice has to reach the live transcriber too.
func cmdMicRecord(seconds: Double, out: String, stream: Bool = false) throws {
    guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: 16_000, channels: 1,
                                     interleaved: false) else {
        throw Err("cannot build 16 kHz mono format")
    }
    let fileSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000.0,
        AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
    var file: AVAudioFile?
    var conv: AVAudioConverter?
    let mic = MicCapture(sampleRate: 16_000)
    guard mic != nil else { throw Err("cannot initialize microphone capture") }
    var failed = false
    func fail(_ message: String) {
        guard !failed else { return }
        failed = true
        FileHandle.standardError.write("ERROR: microphone \(message)\n".data(using: .utf8)!)
        DispatchQueue.main.async {
            mic?.stop()
            file = nil
            exit(1)
        }
    }
    try mic?.start { buf in
        guard !failed else { return }
        if conv == nil {
            conv = AVAudioConverter(from: buf.format, to: outFmt)
            do {
                file = try AVAudioFile(forWriting: URL(fileURLWithPath: out), settings: fileSettings)
            } catch { fail("cannot create audio file: \(error.localizedDescription)"); return }
        }
        guard let conv, let file else { fail("cannot initialize audio conversion"); return }
        let ratio = outFmt.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 1024
        guard let o = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return }
        var err: NSError?
        var supplied = false
        conv.convert(to: o, error: &err) { _, st in
            if supplied { st.pointee = .noDataNow; return nil }
            supplied = true; st.pointee = .haveData; return buf
        }
        if let err { fail("conversion failed: \(err.localizedDescription)"); return }
        guard o.frameLength > 0 else { return }
        do { try file.write(from: o) }
        catch { fail("cannot save audio: \(error.localizedDescription)"); return }
        if stream, let ch = o.floatChannelData?[0] {
            var pcm = Data(capacity: Int(o.frameLength) * 2)
            for i in 0..<Int(o.frameLength) {
                let v = max(-1.0, min(1.0, ch[i]))
                var s16 = Int16(v * 32767.0).littleEndian
                withUnsafeBytes(of: &s16) { pcm.append(contentsOf: $0) }
            }
            FileHandle.standardOutput.write(pcm)
        }
    }
    FileHandle.standardError.write("microphone -> \(out)\n".data(using: .utf8)!)

    // AVAudioFile writes its header when it closes. Killed by SIGTERM - which
    // is exactly how the app stops this process - it never closed, so the file
    // held megabytes of real audio behind a header claiming zero frames. It
    // looked like a silent recording and passed every other check.
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGTERM, SIGINT] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler {
            mic?.stop()
            file = nil          // flush + write the real header
            exit(0)
        }
        src.resume()
        sources.append(src)
    }

    if seconds > 0 { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    else { RunLoop.main.run() }
    mic?.stop()
    file = nil
}

func cmdRecordSplit(seconds: Double, tapOut: String, micOut: String,
                    pids: [pid_t]) throws {
    ensureAudioPermission()
    let all = audioProcesses()
    let targets: [AudioObjectID] = pids.isEmpty
        ? [] : all.filter { pids.contains($0.pid) }.map(\.objID)
    guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: 16_000, channels: 1,
                                     interleaved: false) else {
        throw Err("cannot build 16 kHz mono format")
    }
    let fileSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000.0,
        AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    func makeSink(_ path: String) -> (AVAudioPCMBuffer) -> Void {
        var file: AVAudioFile?
        var conv: AVAudioConverter?
        return { buf in
            if conv == nil {
                conv = AVAudioConverter(from: buf.format, to: outFmt)
                file = try? AVAudioFile(forWriting: URL(fileURLWithPath: path),
                                        settings: fileSettings)
            }
            guard let conv, let file else { return }
            let ratio = outFmt.sampleRate / buf.format.sampleRate
            let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 1024
            guard let o = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap)
            else { return }
            var err: NSError?
            var supplied = false
            conv.convert(to: o, error: &err) { _, st in
                if supplied { st.pointee = .noDataNow; return nil }
                supplied = true; st.pointee = .haveData; return buf
            }
            if err == nil, o.frameLength > 0 { try? file.write(from: o) }
        }
    }

    let tapSink = makeSink(tapOut)
    let micSink = makeSink(micOut)
    let tap = SystemAudioTap()
    try tap.start(targets: targets) { buf, _ in tapSink(buf) }
    var micCapture: MicCapture?
    if let tapFmt = tap.format {
        micCapture = MicCapture(sampleRate: tapFmt.sampleRate)
        do { try micCapture?.start { micSink($0) } }
        catch {
            FileHandle.standardError.write(
                "\u{2192} microphone unavailable: \(error.localizedDescription)\n"
                    .data(using: .utf8)!)
        }
    }
    FileHandle.standardError.write(
        "recording \(seconds)s -> \(tapOut) (them) + \(micOut) (you)\n"
            .data(using: .utf8)!)
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    micCapture?.stop()
    tap.stop()
    print("split recording complete")
}

func cmdRecord(seconds: Double, out: String, pids: [pid_t], mic: Bool = false) throws {
    ensureAudioPermission()
    let all = audioProcesses()
    let targets: [AudioObjectID] = pids.isEmpty
        ? [] : all.filter { pids.contains($0.pid) }.map(\.objID)
    if !pids.isEmpty && targets.isEmpty { throw Err("no audio process objects for pids \(pids)") }

    // Whisper wants 16 kHz mono - convert on the fly so the file is model-ready.
    // Buffer format the converter produces AND that AVAudioFile.write expects
    // (its processingFormat is always Float32 non-interleaved).
    guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                     channels: 1, interleaved: false) else {
        throw Err("cannot build 16 kHz mono output format")
    }
    // On-disk format: 16-bit PCM WAV, which whisper.cpp reads directly.
    let fileSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    let tap = SystemAudioTap()
    var micCapture: MicCapture?
    var mixer: Mixer?
    var file: AVAudioFile?
    var converter: AVAudioConverter?
    var frames: AVAudioFramePosition = 0
    var peak: Float = 0
    var firstAudioAt: CFAbsoluteTime?
    var failure: String?
    let t0 = CFAbsoluteTimeGetCurrent()

    // one place that turns a mono buffer at tap rate into 16 kHz mono on disk
    let consume: (AVAudioPCMBuffer) -> Void = { buf in
        if converter == nil {
            converter = AVAudioConverter(from: buf.format, to: outFmt)
            do { file = try AVAudioFile(forWriting: URL(fileURLWithPath: out),
                                        settings: fileSettings) }
            catch { failure = failure ?? "open: \(error.localizedDescription)" }
        }
        guard let converter, let file else { return }

        // level meter (interleaved: one pointer, frames * channels samples)
        if let ch = buf.floatChannelData?[0] {
            let n = Int(buf.frameLength) * Int(buf.format.channelCount)
            for i in stride(from: 0, to: n, by: 16) { peak = max(peak, abs(ch[i])) }
        }
        if peak > 0.0005 && firstAudioAt == nil { firstAudioAt = CFAbsoluteTimeGetCurrent() }

        let ratio = outFmt.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return }

        var err: NSError?
        var supplied = false
        converter.convert(to: outBuf, error: &err) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return buf
        }
        if let err { failure = failure ?? "convert: \(err.localizedDescription)"; return }
        guard outBuf.frameLength > 0 else { return }
        do {
            try file.write(from: outBuf)
            frames += AVAudioFramePosition(outBuf.frameLength)
        } catch {
            failure = failure ?? "write: \(error.localizedDescription)"
        }
    }

    try tap.start(targets: targets) { buf, _ in
        if mic, let mx = mixer { mx.pushTap(buf) } else { consume(buf) }
    }
    if mic, let tapFmt = tap.format {
        let mx = Mixer(format: tapFmt, onOutput: consume)
        mixer = mx
        micCapture = MicCapture(sampleRate: tapFmt.sampleRate)
        do { try micCapture?.start { mx.pushMic($0) } }
        catch {
            FileHandle.standardError.write(
                "\u{2192} microphone unavailable: \(error.localizedDescription)\n".data(using: .utf8)!)
            mixer = nil
        }
    }
    FileHandle.standardError.write("tap format: \(tap.format?.description ?? "?")\n".data(using: .utf8)!)
    FileHandle.standardError.write("recording \(seconds)s -> \(out) @16kHz mono\n".data(using: .utf8)!)
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    micCapture?.stop()
    tap.stop()
    file = nil   // flush + close the WAV header

    if let failure { throw Err(failure) }
    print("frames=\(frames)  seconds=\(String(format: "%.2f", Double(frames)/outFmt.sampleRate))  peak=\(String(format: "%.4f", peak))")
    if let f = firstAudioAt {
        print("first-audio latency: \(String(format: "%.0f", (f - t0) * 1000)) ms")
    } else {
        print("WARNING: captured only silence (peak \(peak))")
    }
}

func cmdStream(pids: [pid_t], mic: Bool = false) throws {
    ensureAudioPermission()
    let all = audioProcesses()
    let targets: [AudioObjectID] = pids.isEmpty
        ? [] : all.filter { pids.contains($0.pid) }.map(\.objID)
    guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                     channels: 1, interleaved: false) else {
        throw Err("cannot build 16 kHz mono format")
    }
    let tap = SystemAudioTap()
    var micCapture: MicCapture?
    var mixer: Mixer?
    var converter: AVAudioConverter?
    let stdout = FileHandle.standardOutput

    // A tap-bearing aggregate only runs IO while something is playing, so the
    // callback stalls whenever the far side goes quiet or the output device
    // reconfigures. This is a raw byte stream with no timeline in it, so a
    // stall used to leave no trace: the gap vanished and every later sample
    // moved earlier. A real Zoom call came back as a 26.9 s file for a 72.5 s
    // meeting - the far side unintelligible because non-adjacent audio had been
    // spliced together mid-word, and every line attributed to the local speaker
    // because the two files no longer shared a clock.
    //
    // The tap's own sample time is authoritative. Anchor to it and emit the
    // silence each stall stands for.
    var originSampleTime: Double?
    var framesEmitted: Int64 = 0
    var silenceEmitted: Int64 = 0

    func emitSilence(_ frames: Int64) {
        guard frames > 0 else { return }
        var left = Int(frames)
        while left > 0 {
            let n = min(left, 16_000)
            stdout.write(Data(count: n * 2))
            left -= n
        }
        framesEmitted += frames
        silenceEmitted += frames
    }

    /// Emit whatever silence separates this callback from the previous one.
    func closeGap(_ ts: AudioTimeStamp, inputRate: Double) {
        guard ts.mFlags.contains(.sampleTimeValid), inputRate > 0 else { return }
        if originSampleTime == nil { originSampleTime = ts.mSampleTime }
        guard let origin = originSampleTime else { return }
        let expected = Int64((((ts.mSampleTime - origin) * outFmt.sampleRate)
                              / inputRate).rounded())
        // Sub-50 ms differences are ordinary buffer jitter, not a stall.
        let gap = expected - framesEmitted
        guard gap > Int64(0.05 * outFmt.sampleRate) else { return }
        let seconds = Double(gap) / outFmt.sampleRate
        // Worth saying out loud: a long stall means the far side of a call was
        // not being captured at all for that stretch, which the user
        // experiences as "it missed half of what was said".
        if seconds >= 1 {
            let msg = "\u{2192} tap stalled \(String(format: "%.1f", seconds))s"
                + " - no system audio captured for that stretch\n"
            FileHandle.standardError.write(msg.data(using: .utf8)!)
        }
        emitSilence(gap)
    }

    let consume: (AVAudioPCMBuffer) -> Void = { buf in
        if converter == nil { converter = AVAudioConverter(from: buf.format, to: outFmt) }
        guard let converter else { return }
        let ratio = outFmt.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return }
        var err: NSError?
        var supplied = false
        converter.convert(to: outBuf, error: &err) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return buf
        }
        guard err == nil, outBuf.frameLength > 0,
              let ch = outBuf.floatChannelData?[0] else { return }
        // float -> s16le, the format every downstream consumer expects
        var pcm = Data(capacity: Int(outBuf.frameLength) * 2)
        for i in 0..<Int(outBuf.frameLength) {
            let v = max(-1.0, min(1.0, ch[i]))
            var s = Int16(v * 32767.0).littleEndian
            withUnsafeBytes(of: &s) { pcm.append(contentsOf: $0) }
        }
        stdout.write(pcm)
        framesEmitted += Int64(outBuf.frameLength)
    }

    try tap.start(targets: targets) { buf, ts in
        if mic, let mx = mixer {
            mx.pushTap(buf)
        } else {
            closeGap(ts, inputRate: buf.format.sampleRate)
            consume(buf)
        }
    }
    if mic, let tapFmt = tap.format {
        let mx = Mixer(format: tapFmt, onOutput: consume)
        mixer = mx
        micCapture = MicCapture(sampleRate: tapFmt.sampleRate)
        do { try micCapture?.start { mx.pushMic($0) } }
        catch {
            FileHandle.standardError.write(
                "\u{2192} microphone unavailable: \(error.localizedDescription)\n".data(using: .utf8)!)
            mixer = nil
        }
    }
    FileHandle.standardError.write("streaming 16 kHz mono PCM16 to stdout\n".data(using: .utf8)!)
    RunLoop.main.run()   // until killed
}

// Capture children must close their files if the owning app crashes. stdin
// holds the app's library lease until this helper exits. CLI use has no owner
// environment variable and retains its existing standalone lifetime.
private var ownerWatch: DispatchSourceTimer?
if let rawOwner = ProcessInfo.processInfo.environment["SCRIBEBOT_OWNER_PID"],
   let owner = Int32(rawOwner) {
    let watch = DispatchSource.makeTimerSource(queue: .main)
    watch.schedule(deadline: .now() + 1, repeating: 1)
    watch.setEventHandler {
        if getppid() != owner { kill(getpid(), SIGTERM) }
    }
    ownerWatch = watch
    watch.resume()
}

do {
    switch args.count > 1 ? args[1] : "list" {
    case "selftest-rate": try checkCaptureRates()
    case "list": cmdList()
    case "record":
        let mic  = args.contains("--mic")
        let rest = args.filter { $0 != "--mic" }
        let secs = rest.count > 2 ? Double(rest[2]) ?? 5 : 5
        let out  = rest.count > 3 ? rest[3] : "out.wav"
        let pids = rest.dropFirst(4).compactMap { pid_t($0) }
        try cmdRecord(seconds: secs, out: out, pids: Array(pids), mic: mic)
    case "mic":
        let rest = args.filter { !$0.hasPrefix("--") }
        guard rest.count >= 3 else { print("usage: tap mic <out.wav> [secs]"); break }
        try cmdMicRecord(seconds: rest.count > 3 ? (Double(rest[3]) ?? 0) : 0,
                         out: rest[2], stream: args.contains("--stream"))
    case "record-split":
        // rest[0] is the binary path and rest[1] the subcommand
        let rest = args.filter { !$0.hasPrefix("--") }
        guard rest.count >= 5 else {
            print("usage: tap record-split <secs> <them.wav> <you.wav> [pid...]"); break
        }
        try cmdRecordSplit(seconds: Double(rest[2]) ?? 5, tapOut: rest[3],
                           micOut: rest[4],
                           pids: rest.dropFirst(5).compactMap { pid_t($0) })
    case "stream":
        try cmdStream(pids: args.dropFirst(2).filter { $0 != "--mic" }.compactMap { pid_t($0) },
                      mic: args.contains("--mic"))
    default:
        print("usage: tap list | record <secs> <out.wav> [--mic] [pid...] | stream [--mic] [pid...]")
    }
} catch {
    FileHandle.standardError.write("ERROR: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
