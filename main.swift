// Claude Ears for the Mac: lets Claude hear what the Mac is playing while it controls the computer.
//
//   claude-ears listen 10      record 10 s of the Mac's SOUND OUTPUT, print the transcript + labels
//   claude-ears mcp            run as an MCP server (stdio) with the tools listen, ears_off, ears_on, status
//
// Privacy rules (from the design, all enforced here):
//   - Only the Mac's sound output (ScreenCaptureKit audio). NEVER the microphone.
//   - Refuses to listen while the microphone is in use (a call: FaceTime, Zoom, Discord...).
//   - A visible "Claude is listening" notification every time.
//   - Nothing is kept: the recording lives in a temp folder only until it's transcribed, then it's deleted.
//   - Off switch: the ears_off tool, or the file ~/Library/Application Support/claude-ears/OFF.
//   - Transcription is local (whisper.cpp). Nothing is sent anywhere.

import AVFoundation
import CoreAudio
import Foundation
import ScreenCaptureKit

let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/claude-ears")
let offFlag = support.appendingPathComponent("OFF")
let whisper = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "whisper-cli"
let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "ffmpeg"
let model = ProcessInfo.processInfo.environment["CLAUDE_EARS_MODEL"] ?? "/Volumes/important/claude-player/models/ggml-base.en.bin"

// MARK: - Safety checks

/// True while any app is using the default microphone (a call, a voice chat, a recording).
func microphoneInUse() -> Bool {
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr, device != 0 else { return false }
    var running = UInt32(0)
    size = UInt32(MemoryLayout<UInt32>.size)
    addr.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
    guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &running) == noErr else { return false }
    return running != 0
}

func notify(_ text: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "display notification \"\(text)\" with title \"👂 Claude is listening\""]
    try? p.run()
}

// MARK: - Recording the Mac's sound output (ScreenCaptureKit, audio only)

final class Recorder: NSObject, SCStreamOutput {
    var file: AVAudioFile?
    let url: URL
    init(url: URL) { self.url = url }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid, let desc = sb.formatDescription else { return }
        let fmt = AVAudioFormat(cmAudioFormatDescription: desc)
        try? sb.withAudioBufferList { list, _ in
            guard let pcm = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: list.unsafePointer) else { return }
            if file == nil { file = try? AVAudioFile(forWriting: url, settings: fmt.settings) }
            try? file?.write(from: pcm)
        }
    }
}

/// A no-op video output: ScreenCaptureKit wants one even when we only take audio (frames are 2x2 pixels, 1 per second).
final class NoVideo: NSObject, SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {}
}

func record(seconds: Double, to url: URL) async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first else { throw NSError(domain: "ears", code: 1, userInfo: [NSLocalizedDescriptionKey: "no display found"]) }
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let cfg = SCStreamConfiguration()
    cfg.capturesAudio = true
    cfg.excludesCurrentProcessAudio = true
    cfg.sampleRate = 48000
    cfg.channelCount = 2
    cfg.width = 2
    cfg.height = 2
    cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
    let rec = Recorder(url: url)
    let video = NoVideo()
    let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
    let q = DispatchQueue(label: "ears")
    try stream.addStreamOutput(rec, type: .audio, sampleHandlerQueue: q)
    try stream.addStreamOutput(video, type: .screen, sampleHandlerQueue: q)
    try await stream.startCapture()
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    try await stream.stopCapture()
    q.sync { rec.file = nil } // closes the file
}

// MARK: - Understanding it (all local)

@discardableResult
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return (-1, "") }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

struct Heard {
    var transcript: String
    var labels: [String]
    var spectrogram: Data?
}

func understand(_ raw: URL, seconds: Double) -> Heard {
    let dir = raw.deletingLastPathComponent()
    let wav = dir.appendingPathComponent("16k.wav"), png = dir.appendingPathComponent("spec.png")
    run(ffmpeg, ["-v", "error", "-y", "-i", raw.path, "-ac", "1", "-ar", "16000", wav.path])
    // Loudness: mean and max volume.
    let p = Process()
    p.executableURL = URL(fileURLWithPath: ffmpeg)
    p.arguments = ["-v", "info", "-i", wav.path, "-af", "volumedetect", "-f", "null", "-"]
    let err = Pipe()
    p.standardError = err
    p.standardOutput = Pipe()
    try? p.run()
    let stats = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    func db(_ key: String) -> Double? {
        guard let r = stats.range(of: key + ": ") else { return nil }
        return Double(stats[r.upperBound...].prefix { $0 != " " })
    }
    var labels: [String] = []
    let mean = db("mean_volume") ?? -91, peak = db("max_volume") ?? -91
    if peak < -50 { labels.append("[silence]") }
    else if mean < -40 { labels.append("[quiet]") }
    else if mean > -18 { labels.append("[loud]") }
    if peak > -3 && mean < -30 { labels.append("[sudden loud sound]") }
    // Speech (and whisper's own sound tags like [MUSIC], [SCREAMING], [APPLAUSE]).
    var text = ""
    if peak >= -50 {
        let (_, out) = run(whisper, ["-m", model, "-f", wav.path, "-nt", "-np"])
        text = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        for tag in ["MUSIC", "SCREAM", "LAUGH", "APPLAUSE", "SILENCE", "BLANK_AUDIO", "SOUND", "NOISE", "DING", "BEEP", "BELL"] where text.uppercased().contains(tag) {
            labels.append("[\(tag.lowercased().replacingOccurrences(of: "_", with: " "))]")
        }
    }
    // The spectrogram: time left to right, pitch bottom to top, brightness = loudness.
    run(ffmpeg, ["-v", "error", "-y", "-i", wav.path, "-lavfi", "showspectrumpic=s=800x260:legend=1:color=magma:scale=log", png.path])
    return Heard(transcript: text, labels: labels, spectrogram: try? Data(contentsOf: png))
}

/// The whole listen: checks, notification, record, understand, delete. Returns (text, spectrogram PNG).
func listen(seconds: Double) async -> (String, Data?) {
    let secs = min(max(seconds, 1), 30)
    if FileManager.default.fileExists(atPath: offFlag.path) {
        return ("Claude Ears are switched OFF (ears_on, or delete \(offFlag.path)).", nil)
    }
    if microphoneInUse() {
        return ("Not listening: the microphone is in use (probably a call). Claude Ears pause during calls.", nil)
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("claude-ears-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) } // nothing is kept
    notify("Hearing the Mac's sound for \(Int(secs)) s (never the microphone)")
    let raw = dir.appendingPathComponent("raw.caf")
    do {
        try await record(seconds: secs, to: raw)
    } catch {
        return ("Couldn't record: \(error.localizedDescription). Give the app that runs Claude Ears Screen Recording permission (System Settings → Privacy & Security → Screen & System Audio Recording).", nil)
    }
    guard FileManager.default.fileExists(atPath: raw.path) else { return ("[silence] (nothing was playing)", nil) }
    let h = understand(raw, seconds: secs)
    let words = h.transcript.isEmpty ? "(no speech)" : h.transcript
    return ("Heard \(Int(secs)) s of the Mac's sound. Labels: \(h.labels.isEmpty ? "none" : h.labels.joined(separator: " ")). Speech: \(words)", h.spectrogram)
}

// MARK: - MCP server (JSON-RPC over stdio)

func send(_ obj: [String: Any]) {
    if let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) {
        print(s)
        fflush(stdout)
    }
}

let tools: [[String: Any]] = [
    ["name": "listen", "description": "Hear what the Mac is playing right now (its sound OUTPUT only, never the microphone) for 1-30 seconds. Returns speech as text, sound labels ([music], [silence], [loud], [sudden loud sound]...) and a spectrogram picture (time →, pitch ↑, brightness = loudness). Refuses during calls. Nothing is saved.",
     "inputSchema": ["type": "object", "properties": ["seconds": ["type": "number", "description": "1-30, default 8"]]]],
    ["name": "ears_off", "description": "Switch Claude Ears off until ears_on (the user's off switch).", "inputSchema": ["type": "object", "properties": [:]]],
    ["name": "ears_on", "description": "Switch Claude Ears back on.", "inputSchema": ["type": "object", "properties": [:]]],
    ["name": "status", "description": "Are the ears on, is the mic in use (a call), is whisper ready?", "inputSchema": ["type": "object", "properties": [:]]],
]

func serve() async {
    while let line = readLine() {
        guard let data = line.data(using: .utf8), let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
        let id = msg["id"]
        let method = msg["method"] as? String ?? ""
        func reply(_ result: [String: Any]) { if let id { send(["jsonrpc": "2.0", "id": id, "result": result]) } }
        switch method {
        case "initialize":
            reply(["protocolVersion": "2024-11-05", "capabilities": ["tools": [:]], "serverInfo": ["name": "claude-ears", "version": "1.0"]])
        case "tools/list":
            reply(["tools": tools])
        case "tools/call":
            let p = msg["params"] as? [String: Any] ?? [:]
            let args = p["arguments"] as? [String: Any] ?? [:]
            var content: [[String: Any]] = []
            switch p["name"] as? String ?? "" {
            case "listen":
                let (text, png) = await listen(seconds: (args["seconds"] as? Double) ?? 8)
                content.append(["type": "text", "text": text])
                if let png { content.append(["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]) }
            case "ears_off":
                try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: offFlag.path, contents: Data())
                content.append(["type": "text", "text": "Claude Ears are OFF."])
            case "ears_on":
                try? FileManager.default.removeItem(at: offFlag)
                content.append(["type": "text", "text": "Claude Ears are ON."])
            case "status":
                let on = !FileManager.default.fileExists(atPath: offFlag.path)
                content.append(["type": "text", "text": "ears: \(on ? "on" : "OFF") · microphone in use (call): \(microphoneInUse() ? "yes, so listening is paused" : "no") · whisper model: \(FileManager.default.fileExists(atPath: model) ? "ready" : "missing (\(model))")"])
            default:
                content.append(["type": "text", "text": "unknown tool"])
            }
            reply(["content": content])
        default:
            if id != nil { send(["jsonrpc": "2.0", "id": id!, "error": ["code": -32601, "message": "method not found"]]) }
        }
    }
}

// MARK: - main

let args = CommandLine.arguments
switch args.dropFirst().first {
case "mcp":
    await serve()
case "listen":
    let secs = Double(args.count > 2 ? args[2] : "8") ?? 8
    let (text, png) = await listen(seconds: secs)
    print(text)
    if let png, let out = args.count > 3 ? args[3] : nil {
        try? png.write(to: URL(fileURLWithPath: out))
        print("spectrogram: \(out)")
    }
default:
    print("claude-ears listen [seconds] [spectrogram.png]  |  claude-ears mcp")
}
