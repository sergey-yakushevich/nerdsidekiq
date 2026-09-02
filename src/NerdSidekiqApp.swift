import SwiftUI
import AppKit
import AVFoundation
import ServiceManagement
import notify

// NerdSidekiq — the UI lives in the floating Electron overlay (overlay/).
// This app records mic (L) + system audio (R), spawns the python loops and
// the post-call pipeline, and keeps a minimal status window.
//
// The overlay controls the recorder with darwin notifications:
//   notifyutil -p dev.cyberjosef.nerdsidekiq.start
//   notifyutil -p dev.cyberjosef.nerdsidekiq.finish
// The session mode + prep config are read from <base>/session.json:
//   {"mode": "transcript"|"sidekiq"|"prep", "about": "...", "notes_path": "..."}

let baseDir: URL = {
    // .../nerdsidekiq/build/NerdSidekiq.app -> .../nerdsidekiq
    URL(fileURLWithPath: Bundle.main.bundlePath)
        .deletingLastPathComponent()   // build
        .deletingLastPathComponent()   // nerdsidekiq
}()

// The pipeline python: project venv (has the anthropic SDK), system fallback.
let pythonPath: String = {
    let venv = baseDir.appendingPathComponent(".venv/bin/python3").path
    return FileManager.default.fileExists(atPath: venv) ? venv : "/usr/bin/python3"
}()

let antPath = "/opt/homebrew/bin/ant"

let modelChoices = ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5",
                    "claude-opus-4-8"]

func appLog(_ s: String) {
    let dir = baseDir.appendingPathComponent("logs")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = dir.appendingPathComponent("app.log")
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(stamp)] \(s)\n"
    if let h = try? FileHandle(forWritingTo: f) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        try? h.close()
    } else {
        try? line.write(to: f, atomically: true, encoding: .utf8)
    }
}

enum Phase: Equatable {
    case idle
    case recording(Date)
    case processing
}

@MainActor
final class AppModel: ObservableObject {
    @Published var phase: Phase = .idle
    @Published var status: String = "Ready."
    @Published var notionURL: String? = nil
    @Published var micLevel: Float = 0
    @Published var sysLevel: Float = 0
    @Published var elapsed: String = "00:00"

    @Published var hintsEnabled: Bool = false {
        didSet { saveSettings() }
    }
    @Published var answerModel: String = "claude-opus-5" {
        didSet { saveSettings() }
    }
    @Published var rollingModel: String = "claude-opus-5" {
        didSet { saveSettings() }
    }
    @Published var transcriptDir: String = baseDir.appendingPathComponent("recordings").path {
        didSet { saveSettings() }
    }
    @Published var onboardingDone: Bool = false {
        didSet {
            saveSettings()
            if onboardingDone && !loadingSettings {
                startOverlay()
                AppModel.hideMainApp()
            }
        }
    }
    @Published var sysAudioVerified: Bool = false {
        didSet { saveSettings() }
    }
    @Published var claudeStatus: String = "Checking…"
    @Published var claudeConnected: Bool = false
    @Published var claudeBusy: Bool = false

    // permissions (onboarding gate)
    @Published var micStatus: AVAuthorizationStatus = .notDetermined
    @Published var probing: Bool = false
    @Published var probeMessage: String = ""

    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet { applyLaunchAtLogin() }
    }

    let recorder = Recorder()
    private var sessionDir: URL? = nil
    private var rawPath: URL? = nil
    private var currentMode: String = "transcript"
    private var liveProc: Process? = nil
    private var overlayProc: Process? = nil
    private var timer: Timer? = nil
    private var loadingSettings = false

    init() {
        loadSettings()
        refreshMicStatus()
        registerControlNotifications()
        if onboardingDone { startOverlay() }
    }

    private var settingsFile: URL { baseDir.appendingPathComponent("settings.json") }

    private func loadSettings() {
        loadingSettings = true
        defer { loadingSettings = false }
        if let data = try? Data(contentsOf: settingsFile),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            hintsEnabled = obj["hints"] as? Bool ?? false
            answerModel = obj["answer_model"] as? String ?? "claude-opus-5"
            rollingModel = obj["rolling_model"] as? String ?? "claude-opus-5"
            transcriptDir = obj["transcript_dir"] as? String
                ?? baseDir.appendingPathComponent("recordings").path
            onboardingDone = obj["onboarding_done"] as? Bool ?? false
            sysAudioVerified = obj["sys_audio_verified"] as? Bool ?? false
        }
    }

    private func saveSettings() {
        if loadingSettings { return }
        let obj: [String: Any] = ["hints": hintsEnabled,
                                  "answer_model": answerModel,
                                  "rolling_model": rollingModel,
                                  "transcript_dir": transcriptDir,
                                  "onboarding_done": onboardingDone,
                                  "sys_audio_verified": sysAudioVerified]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
            try? data.write(to: settingsFile)
        }
    }

    // ---------- permissions ----------

    func refreshMicStatus() {
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            appLog("microphone permission: \(ok ? "granted" : "DENIED")")
            Task { @MainActor in self.refreshMicStatus() }
        }
    }

    /// Verifies the System Audio Recording permission with a real check:
    /// starts the tap, plays a short system sound, and looks for signal on
    /// the system channel. The first run triggers the macOS prompt.
    func probeSystemAudio() {
        guard case .idle = phase, !probing else { return }
        probing = true
        probeMessage = "Playing a test sound…"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ns-probe-\(getpid()).raw")
        do {
            try recorder.start(outPath: tmp.path)
        } catch {
            probing = false
            probeMessage = "Could not start audio capture: \(error)"
            return
        }
        let play = Process()
        play.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        play.arguments = ["/System/Library/Sounds/Glass.aiff"]
        try? play.run()
        recorder.resetPeaks()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self else { return }
            let sysPeak = self.recorder.sysPeak
            _ = self.recorder.stop()
            try? FileManager.default.removeItem(at: tmp)
            self.probing = false
            if sysPeak > 0.001 {
                self.sysAudioVerified = true
                self.probeMessage = "System audio verified — the test sound was captured."
                appLog("system audio probe OK (peak \(sysPeak))")
            } else {
                self.sysAudioVerified = false
                self.probeMessage = "No system audio captured. Allow \"System Audio Recording\" "
                    + "in the macOS prompt (or System Settings → Privacy & Security "
                    + "→ Screen & System Audio Recording), then test again."
                appLog("system audio probe SILENT")
            }
        }
    }

    // ---------- transcripts folder ----------

    func chooseTranscriptFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Use this folder"
        panel.message = "Transcripts and recordings are saved here, one folder per call."
        panel.directoryURL = URL(fileURLWithPath: transcriptDir)
        if panel.runModal() == .OK, let u = panel.url {
            transcriptDir = u.path
        }
    }

    func revealTranscriptFolder() {
        let dir = URL(fileURLWithPath: transcriptDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    // ---------- launch at login ----------

    private func applyLaunchAtLogin() {
        if loadingSettings { return }
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            appLog("launch-at-login failed: \(error)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    // ---------- Claude account (ant CLI OAuth profile) ----------

    nonisolated private func runAnt(_ args: [String]) -> (Int32, String) {
        guard FileManager.default.fileExists(atPath: antPath) else {
            return (127, "ant CLI not installed (brew install anthropics/tap/ant)")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: antPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (126, "\(error)") }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        return (p.terminationStatus, out)
    }

    func refreshClaudeStatus() {
        claudeStatus = "Checking…"
        Task.detached { [weak self] in
            guard let self else { return }
            let (code, out) = await self.runAnt(["auth", "status"])
            await MainActor.run {
                if code != 0 {
                    self.claudeConnected = false
                    self.claudeStatus = out.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if out.contains("not configured") {
                    self.claudeConnected = false
                    self.claudeStatus = "Not connected — click Authorize."
                } else {
                    self.claudeConnected = true
                    // "✓ ... as user@mail (profile ...)" appears in login output;
                    // status shows the profile paths — keep it short.
                    self.claudeStatus = "Connected (profile \"default\")."
                }
            }
        }
    }

    func authorizeClaude() {
        guard !claudeBusy else { return }
        claudeBusy = true
        claudeStatus = "Waiting for the browser sign-in…"
        Task.detached { [weak self] in
            guard let self else { return }
            let (code, out) = await self.runAnt(["auth", "login"])
            await MainActor.run {
                self.claudeBusy = false
                if code != 0 {
                    self.claudeStatus = "Login failed: " +
                        (out.trimmingCharacters(in: .whitespacesAndNewlines)
                            .split(separator: "\n").last.map(String.init) ?? "unknown error")
                }
                self.refreshClaudeStatus()
            }
        }
    }

    private func registerControlNotifications() {
        var t1: Int32 = 0, t2: Int32 = 0
        let r1 = notify_register_dispatch("dev.cyberjosef.nerdsidekiq.start", &t1, DispatchQueue.main) { _ in
            appLog("control: start notification")
            Task { @MainActor in AppModel.shared?.startCall(headless: true) }
        }
        let r2 = notify_register_dispatch("dev.cyberjosef.nerdsidekiq.finish", &t2, DispatchQueue.main) { _ in
            appLog("control: finish notification")
            Task { @MainActor in AppModel.shared?.finishCall(headless: true) }
        }
        var t3: Int32 = 0, t4: Int32 = 0
        notify_register_dispatch("dev.cyberjosef.nerdsidekiq.settings", &t3, DispatchQueue.main) { _ in
            Task { @MainActor in AppModel.shared?.openSettings() }
        }
        notify_register_dispatch("dev.cyberjosef.nerdsidekiq.quit", &t4, DispatchQueue.main) { _ in
            appLog("control: quit notification")
            Task { @MainActor in NSApp.terminate(nil) }
        }
        appLog("control notifications registered (start=\(r1) finish=\(r2))")
    }

    /// The overlay IS the app: once onboarding is done the Swift process
    /// runs as an accessory — no Dock icon, no status window.
    static func hideMainApp() {
        NSApp.setActivationPolicy(.accessory)
        for w in NSApp.windows where w.identifier?.rawValue == "main" { w.close() }
    }

    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    /// Called from applicationWillTerminate: never leave a half-open
    /// session behind (files stay in the folder, pipeline is skipped).
    func shutdown() {
        if case .recording = phase {
            _ = recorder.stop()
            if let p = liveProc, p.isRunning { p.terminate() }
            appLog("quit while recording — session left unprocessed")
        }
        stopOverlay()
    }

    static weak var shared: AppModel?

    /// session.json is written by the overlay right before it posts the
    /// start notification. Legacy/headless starts without it get "transcript".
    private func readSessionConfig() -> (mode: String, about: String, notes: String) {
        let f = baseDir.appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: f),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ("transcript", "", "") }
        return (obj["mode"] as? String ?? "transcript",
                obj["about"] as? String ?? "",
                obj["notes_path"] as? String ?? "")
    }

    nonisolated func postOverlay(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let url = URL(string: "http://127.0.0.1:17865/assist") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: req).resume()
    }

    func startCall(headless: Bool = false) {
        guard case .idle = phase else { return }
        let cfg = readSessionConfig()
        currentMode = cfg.mode
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        let dir = URL(fileURLWithPath: transcriptDir)
            .appendingPathComponent("\(df.string(from: Date()))-\(cfg.mode)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let raw = dir.appendingPathComponent("call.raw")

        do {
            try recorder.start(outPath: raw.path)
        } catch {
            status = "Error: \(error)"
            appLog("start failed: \(error)")
            postOverlay(["type": "phase", "phase": "error",
                         "text": "Audio capture failed — check permissions."])
            return
        }
        sessionDir = dir
        rawPath = raw
        notionURL = nil
        phase = .recording(Date())
        status = cfg.mode == "prep" ? "Mock interview running…" : "Recording…"
        appLog("recording started -> \(raw.path) (mode: \(cfg.mode))")
        startOverlay()
        if cfg.mode == "prep" {
            let prep: [String: Any] = ["about": cfg.about, "notes_path": cfg.notes]
            if let d = try? JSONSerialization.data(withJSONObject: prep,
                                                   options: [.prettyPrinted]) {
                try? d.write(to: dir.appendingPathComponent("prep.json"))
            }
            startLoop(script: "prep_loop.py", dir: dir, env: [:])
        } else {
            startLoop(script: "live_loop.py", dir: dir,
                      env: ["NERDSIDEKIQ_MODE": cfg.mode])
        }
        postOverlay(["type": "phase", "phase": "recording", "mode": cfg.mode])

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor in self.tick() }
        }
    }

    private func startLoop(script: String, dir: URL, env: [String: String]) {
        let path = baseDir.appendingPathComponent(script)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = [path.path, dir.path]
        if !env.isEmpty {
            var e = ProcessInfo.processInfo.environment
            env.forEach { e[$0] = $1 }
            proc.environment = e
        }
        let logFile = dir.appendingPathComponent("live.log")
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let h = try? FileHandle(forWritingTo: logFile)
        proc.standardOutput = h
        proc.standardError = h
        proc.terminationHandler = { _ in try? h?.close() }
        do {
            try proc.run()
            liveProc = proc
            appLog("\(script) started (pid \(proc.processIdentifier))")
        } catch {
            appLog("\(script) spawn failed: \(error)")
        }
    }

    func startOverlay() {
        guard overlayProc == nil || !(overlayProc?.isRunning ?? false) else { return }
        let overlayDir = baseDir.appendingPathComponent("overlay")
        let electron = overlayDir.appendingPathComponent(
            "node_modules/electron/dist/Electron.app/Contents/MacOS/Electron")
        guard FileManager.default.fileExists(atPath: electron.path) else {
            appLog("overlay: electron not installed (run npm install in overlay/)")
            return
        }
        let proc = Process()
        proc.executableURL = electron
        proc.arguments = [overlayDir.path]
        do {
            try proc.run()
            overlayProc = proc
            appLog("overlay started (pid \(proc.processIdentifier))")
        } catch {
            appLog("overlay spawn failed: \(error)")
        }
    }

    func stopOverlay() {
        if let p = overlayProc, p.isRunning { p.terminate() }
        overlayProc = nil
    }

    private func tick() {
        guard case .recording(let started) = phase else { return }
        let s = Int(Date().timeIntervalSince(started))
        elapsed = String(format: "%02d:%02d", s / 60, s % 60)
        micLevel = min(1, recorder.micPeak * 3)
        sysLevel = min(1, recorder.sysPeak * 3)
        recorder.resetPeaks()
        if notionURL == nil, let dir = sessionDir,
           let data = try? Data(contentsOf: dir.appendingPathComponent("live.json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let url = obj["parent_url"] as? String {
            notionURL = url
            status = "Recording — live note is updating in Notion."
        }
    }

    func finishCall(headless: Bool = false) {
        guard case .recording = phase else { return }
        timer?.invalidate()
        timer = nil
        let stats = recorder.stop()
        appLog(String(format: "recording stopped: %.1fs, micRMS=%.5f sysRMS=%.5f",
                      stats.seconds, stats.micRMS, stats.sysRMS))
        guard let dir = sessionDir, rawPath != nil else {
            phase = .idle
            return
        }
        phase = .processing
        micLevel = 0; sysLevel = 0
        let mode = currentMode
        status = mode == "prep" ? "Saving the practice session…"
                                : "Finishing — transcript, final summary, Notion…"
        postOverlay(["type": "phase", "phase": "processing"])

        let live = liveProc
        liveProc = nil
        Task.detached {
            if let live, live.isRunning {
                live.terminate()          // SIGTERM: the loop saves its state
                live.waitUntilExit()
            }
            await MainActor.run {
                if mode == "prep" {
                    // practice sessions stay local: dialogue + audio in the
                    // session folder, no Notion note, no re-transcription
                    self.status = "Practice session saved: \(dir.lastPathComponent)"
                    self.phase = .idle
                    self.postOverlay(["type": "phase", "phase": "saved",
                                      "title": "Practice session saved (local folder)"])
                    appLog("prep session saved: \(dir.path)")
                } else {
                    self.runPipeline(dir: dir)
                }
            }
        }
    }

    private func runPipeline(dir: URL) {
        let script = baseDir.appendingPathComponent("process_call.py")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = [script.path, dir.path]
        let logFile = dir.appendingPathComponent("pipeline.log")
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let h = try? FileHandle(forWritingTo: logFile)
        proc.standardOutput = h
        proc.standardError = h
        proc.terminationHandler = { p in
            try? h?.close()
            Task { @MainActor in
                if p.terminationStatus == 0,
                   let data = try? Data(contentsOf: dir.appendingPathComponent("result.json")),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let url = obj["notion_url"] as? String
                    let lang = obj["language"] as? String ?? "?"
                    let title = obj["title"] as? String ?? ""
                    self.notionURL = url
                    self.status = "Saved to Notion (\(lang)): \(title)"
                    appLog("pipeline ok: \(url ?? "no url")")
                    self.postOverlay(["type": "phase", "phase": "saved",
                                      "title": title, "url": url ?? ""])
                } else {
                    self.status = "Pipeline failed — see \(logFile.path)"
                    appLog("pipeline FAILED (exit \(p.terminationStatus)) — \(logFile.path)")
                    self.postOverlay(["type": "phase", "phase": "error",
                                      "text": "Pipeline failed — see pipeline.log"])
                }
                self.phase = .idle
            }
        }
        do {
            try proc.run()
        } catch {
            status = "Cannot run pipeline: \(error)"
            appLog("pipeline spawn failed: \(error)")
            phase = .idle
        }
    }
}

// The overlay is the whole UI. The Swift window exists only for the
// first-run onboarding wizard; afterwards the app runs as an accessory.

final class AppDelegate: NSObject, NSApplicationDelegate {
    // the app lives in the overlay — closing the (onboarding) window
    // must not quit the process
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            if AppModel.shared?.onboardingDone == true {
                DispatchQueue.main.async { AppModel.hideMainApp() }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared?.shutdown()
        }
    }
}

@main
struct NerdSidekiqApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel

    init() {
        let m = AppModel()
        AppModel.shared = m
        _model = StateObject(wrappedValue: m)
        appLog("app launched")
    }

    var body: some Scene {
        Window("NerdSidekiq", id: "main") {
            if !model.onboardingDone {
                OnboardingView(model: model)
            }
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsRootView(model: model)
                .onAppear {
                    model.refreshMicStatus()
                    model.refreshClaudeStatus()
                }
        }
        .windowResizability(.contentSize)
    }
}
