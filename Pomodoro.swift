import SwiftUI
import AppKit
import UserNotifications
import CoreAudio
import Carbon.HIToolbox

// MARK: - Varieties and break ideas

struct Variety: Identifiable, Hashable {
    let id: String
    let name: String
    let blurb: String
    let focus: TimeInterval
    let short: TimeInterval
    let long: TimeInterval
    let rounds: Int

    // Identity is the id alone, so the Custom entry stays selected while its numbers change.
    static func == (a: Variety, b: Variety) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The user's own durations, in minutes.
struct CustomSpec: Codable, Equatable {
    var focus = 25
    var short = 5
    var long = 15
    var rounds = 4

    var variety: Variety {
        Variety(id: "custom", name: "Custom",
                blurb: "\(focus) on, \(short) off. A \(long) minute break after \(rounds) rounds.",
                focus: TimeInterval(focus * 60), short: TimeInterval(short * 60),
                long: TimeInterval(long * 60), rounds: rounds)
    }
}

let varieties: [Variety] = [
    Variety(id: "classic", name: "Classic", blurb: "25 on, 5 off. A long break after 4 rounds.",
            focus: 25 * 60, short: 5 * 60, long: 15 * 60, rounds: 4),
    Variety(id: "sprint", name: "Sprint", blurb: "15 on, 3 off. For when starting is the hard part.",
            focus: 15 * 60, short: 3 * 60, long: 10 * 60, rounds: 4),
    Variety(id: "deep", name: "Deep work", blurb: "50 on, 10 off, two rounds, then a proper rest.",
            focus: 50 * 60, short: 10 * 60, long: 25 * 60, rounds: 2),
    Variety(id: "flow", name: "Flow", blurb: "90 on, 20 off. One big block, twice.",
            focus: 90 * 60, short: 20 * 60, long: 30 * 60, rounds: 2),
    Variety(id: "demo", name: "Try it (10 sec)", blurb: "Ten-second rounds, to test the chime and music pausing.",
            focus: 10, short: 5, long: 8, rounds: 2),
]

let shortBreakIdeas = [
    "Stand up and roll your shoulders and neck",
    "Look out a window at something far away for 20 seconds",
    "Drink a glass of water",
    "Walk to another room and back",
    "Five slow breaths: in for 4, out for 6",
    "Ten squats or a few push-ups",
    "Tidy one small thing on your desk",
    "Close your eyes for a minute",
]

let longBreakIdeas = [
    "Go outside for a short walk",
    "Make something to eat, or a proper coffee",
    "Step away from screens entirely",
    "Do a quick stretch routine",
    "Water a plant, wash a mug, reset the room",
    "Jot down what you got done and what's next",
]

// MARK: - Notifications

final class NotifyDelegate: NSObject, UNUserNotificationCenterDelegate {
    // Without this, banners are swallowed while the app counts as "active".
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner])
    }
}

// MARK: - Global hotkey

/// A global shortcut: a key plus Carbon modifier flags, and how to show it.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String

    static let standard = Shortcut(keyCode: UInt32(kVK_ANSI_T),
                                   modifiers: UInt32(controlKey | optionKey), label: "⌃⌥T")
}

/// Registered through Carbon so it works without Accessibility permission.
final class HotKey {
    var onPress: () -> Void = {}
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var current: Shortcut?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().onPress()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    /// Registers `shortcut`, or nothing when nil. If the new one is refused, the previous one stays active.
    @discardableResult
    func set(_ shortcut: Shortcut?) -> Bool {
        let previous = current
        unregister()
        guard let shortcut else { return true }
        if register(shortcut) { return true }
        if let previous { _ = register(previous) }
        return false
    }

    private func register(_ s: Shortcut) -> Bool {
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(s.keyCode, s.modifiers,
                                         EventHotKeyID(signature: OSType(0x544D5452), id: 1),
                                         GetApplicationEventTarget(), 0, &newRef)
        guard status == noErr else { return false }
        ref = newRef
        current = s
        return true
    }

    private func unregister() {
        if let r = ref { UnregisterEventHotKey(r) }
        ref = nil
        current = nil
    }
}

// MARK: - Event log

/// One JSON object per line, for analysing your own focus time.
enum EventLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/TomatoTime/events.log")

    static func write(_ fields: [String: Any]) {
        var entry = fields
        entry["time"] = ISO8601DateFormatter().string(from: Date())
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }
}

// MARK: - Model

@MainActor
final class PomodoroModel: ObservableObject {
    static let shared = PomodoroModel()

    enum Phase: String { case focus, shortBreak, longBreak }

    @Published var variety: Variety {
        didSet {
            UserDefaults.standard.set(variety.id, forKey: "variety")
            reset()
        }
    }
    @Published var customSpec: CustomSpec {
        didSet {
            if let data = try? JSONEncoder().encode(customSpec) {
                UserDefaults.standard.set(data, forKey: "customSpec")
            }
            if variety.id == "custom" { variety = customSpec.variety }
        }
    }
    @Published var hotKeyEnabled: Bool {
        didSet {
            UserDefaults.standard.set(hotKeyEnabled, forKey: "hotKeyEnabled")
            hotKey.set(hotKeyEnabled ? shortcut : nil)
        }
    }
    @Published private(set) var shortcut: Shortcut
    @Published private(set) var recording = false
    @Published private(set) var shortcutError: String?
    @Published var autoContinue: Bool {
        didSet { UserDefaults.standard.set(autoContinue, forKey: "autoContinue") }
    }
    @Published var pauseOthers: Bool {
        didSet {
            UserDefaults.standard.set(pauseOthers, forKey: "pauseOthers")
            if pauseOthers { _ = CGRequestPostEventAccess() }
        }
    }
    @Published private(set) var phase: Phase = .focus
    @Published private(set) var round = 1
    @Published private(set) var remaining: TimeInterval
    @Published private(set) var running = false
    @Published private(set) var suggestion = ""

    private var endDate: Date?
    private var timer: Timer?
    private var pausedPlayers: [String] = []
    private var sentMediaKey = false
    private let notifyDelegate = NotifyDelegate()
    private let hotKey = HotKey()
    private var recordMonitor: Any?

    var allVarieties: [Variety] { varieties + [customSpec.variety] }

    init() {
        let d = UserDefaults.standard
        let spec = d.data(forKey: "customSpec").flatMap { try? JSONDecoder().decode(CustomSpec.self, from: $0) } ?? CustomSpec()
        customSpec = spec
        let saved = d.string(forKey: "variety")
        let v = saved == "custom" ? spec.variety : (varieties.first { $0.id == saved } ?? varieties[0])
        variety = v
        remaining = v.focus
        autoContinue = d.object(forKey: "autoContinue") as? Bool ?? true
        pauseOthers = d.object(forKey: "pauseOthers") as? Bool ?? true
        hotKeyEnabled = d.object(forKey: "hotKeyEnabled") as? Bool ?? true
        shortcut = d.data(forKey: "shortcut").flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .standard
        if pauseOthers && !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }

        hotKey.onPress = { [weak self] in Task { @MainActor in self?.toggle() } }
        hotKey.set(hotKeyEnabled ? shortcut : nil)

        if Bundle.main.bundleIdentifier != nil {
            let center = UNUserNotificationCenter.current()
            center.delegate = notifyDelegate
            center.requestAuthorization(options: [.alert]) { _, _ in }
        }
    }

    // MARK: Derived

    var phaseDuration: TimeInterval {
        switch phase {
        case .focus: return variety.focus
        case .shortBreak: return variety.short
        case .longBreak: return variety.long
        }
    }

    var progress: Double { phaseDuration > 0 ? 1 - remaining / phaseDuration : 0 }

    var phaseLabel: String {
        switch phase {
        case .focus: return "Focus · round \(round) of \(variety.rounds)"
        case .shortBreak: return "Short break"
        case .longBreak: return "Long break"
        }
    }

    var timeString: String {
        let s = Int(ceil(max(0, remaining)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    var menuTitle: String {
        let fresh = !running && phase == .focus && round == 1 && remaining == variety.focus
        if fresh { return "🍅" }
        let icon = !running ? "⏸" : (phase == .focus ? "🍅" : "☕️")
        return "\(icon) \(timeString)"
    }

    // MARK: Controls

    func toggle() { running ? pause() : start() }

    /// Handles tomatotime://startStop, start, pause, skip and reset.
    func handle(url: URL) {
        guard url.scheme == "tomatotime" else { return }
        switch url.host?.lowercased() {
        case "startstop": toggle()
        case "start": start()
        case "pause": pause()
        case "skip": skip()
        case "reset": reset()
        default: break
        }
    }

    // MARK: Shortcut recording

    /// Listens for the next key combination. Esc cancels; at least one of ⌃ ⌥ ⌘ is required.
    func beginRecording() {
        guard recordMonitor == nil else { return }
        recording = true
        shortcutError = nil
        hotKey.set(nil)  // so pressing the current combo doesn't toggle the timer
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.capture(event) }
            return nil
        }
    }

    func endRecording() {
        guard recordMonitor != nil else { return }
        if let m = recordMonitor { NSEvent.removeMonitor(m) }
        recordMonitor = nil
        recording = false
        hotKey.set(hotKeyEnabled ? shortcut : nil)
    }

    func resetShortcut() {
        endRecording()
        apply(.standard)
    }

    private func capture(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { endRecording(); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.control) || flags.contains(.option) || flags.contains(.command) else {
            shortcutError = "Include ⌃, ⌥ or ⌘ in the shortcut."
            return
        }
        var mods: UInt32 = 0
        var label = ""
        if flags.contains(.control) { mods |= UInt32(controlKey); label += "⌃" }
        if flags.contains(.option) { mods |= UInt32(optionKey); label += "⌥" }
        if flags.contains(.shift) { mods |= UInt32(shiftKey); label += "⇧" }
        if flags.contains(.command) { mods |= UInt32(cmdKey); label += "⌘" }
        let key = event.keyCode == UInt16(kVK_Space) ? "Space" : (event.charactersIgnoringModifiers ?? "?").uppercased()
        let new = Shortcut(keyCode: UInt32(event.keyCode), modifiers: mods, label: label + key)

        endRecording()
        apply(new)
    }

    private func apply(_ new: Shortcut) {
        let old = shortcut
        if hotKeyEnabled && !hotKey.set(new) {
            hotKey.set(old)
            shortcutError = "\(new.label) is already taken. Kept \(old.label)."
            return
        }
        shortcut = new
        shortcutError = nil
        if let data = try? JSONEncoder().encode(new) { UserDefaults.standard.set(data, forKey: "shortcut") }
    }

    private func log(_ event: String) {
        EventLog.write(["event": event, "phase": phase.rawValue, "round": round,
                        "style": variety.id, "remaining": Int(max(0, remaining))])
    }

    func start() {
        guard !running else { return }
        log("start")
        endDate = Date().addingTimeInterval(remaining)
        running = true
        // .common so it keeps ticking while the popover is open.
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if phase == .focus { resumeMedia() }
    }

    func pause() {
        guard running else { return }
        remaining = max(0, endDate?.timeIntervalSinceNow ?? remaining)
        stopTimer()
        log("pause")
    }

    func reset() {
        log("reset")
        stopTimer()
        phase = .focus
        round = 1
        remaining = variety.focus
        suggestion = ""
    }

    func skip() {
        log("skip")
        let wasRunning = running
        stopTimer()
        let cycleDone = advance()
        if wasRunning && !cycleDone { start() }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        endDate = nil
        running = false
    }

    private func tick() {
        guard let end = endDate else { return }
        remaining = end.timeIntervalSinceNow
        if remaining <= 0 { finishPhase() }
    }

    private func finishPhase() {
        let ended = phase
        log("phase_end")
        stopTimer()
        let cycleDone = advance()
        alert(after: ended)
        if autoContinue && !cycleDone { start() }
    }

    /// Moves to the next phase. Returns true when a whole cycle just finished.
    @discardableResult
    private func advance() -> Bool {
        var cycleDone = false
        switch phase {
        case .focus:
            phase = round >= variety.rounds ? .longBreak : .shortBreak
        case .shortBreak:
            round += 1
            phase = .focus
        case .longBreak:
            round = 1
            phase = .focus
            cycleDone = true
        }
        remaining = phaseDuration
        switch phase {
        case .focus: suggestion = ""
        case .shortBreak: suggestion = shortBreakIdeas.randomElement() ?? ""
        case .longBreak: suggestion = longBreakIdeas.randomElement() ?? ""
        }
        return cycleDone
    }

    // MARK: Alert

    private func alert(after ended: Phase) {
        let title: String
        let body: String
        switch ended {
        case .focus:
            title = phase == .longBreak ? "Round done. Long break." : "Round done. Take five."
            body = suggestion
        case .shortBreak:
            title = "Back to it"
            body = "Round \(round) of \(variety.rounds)"
        case .longBreak:
            title = "Cycle complete 🎉"
            body = "Start another whenever you like."
        }
        Task { @MainActor in
            // Only when focus ends: a break ending shouldn't silence music you chose to play.
            if ended == .focus { await pauseMedia() }
            NSSound(named: ended == .focus ? "Glass" : "Hero")?.play()
            notify(title: title, body: body)
        }
    }

    private func notify(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: Music

    private let players = [("Music", "com.apple.Music"), ("Spotify", "com.spotify.client")]

    private func pauseMedia() async {
        pausedPlayers = []
        sentMediaKey = false
        // 1. Music and Spotify: asked directly, and only paused if they are playing.
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        for (name, bundle) in players where running.contains(bundle) {
            let source = """
            tell application "\(name)"
                if player state is playing then
                    pause
                    return "paused"
                end if
            end tell
            return "idle"
            """
            if runScript(source) == "paused" { pausedPlayers.append(name) }
        }
        guard pauseOthers else { return }
        // 2. Anything else (browsers, video players, podcasts): if the Mac is still
        // producing sound once the apps above have stopped, send the Play/Pause key.
        // The key is a toggle, so it is only sent when sound is actually playing.
        try? await Task.sleep(nanoseconds: 600_000_000)
        if isAudioPlaying() {
            sendPlayPauseKey()
            sentMediaKey = true
        }
    }

    /// True if any app is currently sending sound to the default output device.
    private func isAudioPlaying() -> Bool {
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &deviceID) == noErr else { return false }
        var active: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &active) == noErr else { return false }
        return active != 0
    }

    private func resumeMedia() {
        for name in pausedPlayers { _ = runScript("tell application \"\(name)\" to play") }
        if sentMediaKey { sendPlayPauseKey() }
        pausedPlayers = []
        sentMediaKey = false
    }

    private func runScript(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return result?.stringValue
    }

    private func sendPlayPauseKey() {
        func post(down: Bool) {
            let flags: Int = down ? 0xA00 : 0xB00
            let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                timestamp: 0, windowNumber: 0, context: nil,
                subtype: 8, data1: (16 << 16) | flags, data2: -1)  // 16 = NX_KEYTYPE_PLAY
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
        post(down: true)
        post(down: false)
    }
}

// MARK: - UI

struct PopoverView: View {
    @EnvironmentObject var m: PomodoroModel

    private var tint: Color { m.phase == .focus ? .red : .teal }

    var body: some View {
        VStack(spacing: 14) {
            ring
            dots
            controls

            if m.phase != .focus && !m.suggestion.isEmpty {
                VStack(spacing: 2) {
                    Text("Break idea").font(.caption).foregroundStyle(.secondary)
                    Text(m.suggestion).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(10)
                .background(.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Picker("Style", selection: $m.variety) {
                    ForEach(m.allVarieties) { Text($0.name).tag($0) }
                }
                Text(m.variety.blurb).font(.caption).foregroundStyle(.secondary)
                if m.variety.id == "custom" {
                    Stepper("Focus: \(m.customSpec.focus) min", value: $m.customSpec.focus, in: 1...180)
                    Stepper("Short break: \(m.customSpec.short) min", value: $m.customSpec.short, in: 1...60)
                    Stepper("Long break: \(m.customSpec.long) min", value: $m.customSpec.long, in: 1...120)
                    Stepper("Rounds: \(m.customSpec.rounds)", value: $m.customSpec.rounds, in: 1...12)
                }
                Toggle("Keep going automatically", isOn: $m.autoContinue)
                HStack {
                    Toggle("Global hotkey", isOn: $m.hotKeyEnabled)
                    Spacer()
                    Button(m.recording ? "Press keys…" : m.shortcut.label) {
                        m.recording ? m.endRecording() : m.beginRecording()
                    }
                    .disabled(!m.hotKeyEnabled)
                    if m.shortcut != .standard && !m.recording {
                        Button("Reset") { m.resetShortcut() }
                    }
                }
                if let error = m.shortcutError {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else if m.recording {
                    Text("Press the new shortcut, or Esc to cancel.").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Pause browsers and other apps too", isOn: $m.pauseOthers)
                if m.pauseOthers {
                    Text("Uses the Play/Pause key when sound is still playing. Needs Accessibility permission.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("Pauses music and videos when the bell rings").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 300)
        .onDisappear { m.endRecording() }
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.15), lineWidth: 10)
            Circle()
                .trim(from: 0, to: m.progress)
                .stroke(tint, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: m.progress)
            VStack(spacing: 2) {
                Text(m.timeString)
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(m.phaseLabel).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: 180, height: 180)
        .padding(.top, 4)
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(0..<m.variety.rounds, id: \.self) { i in
                let done = i < m.round - 1 || (i == m.round - 1 && m.phase != .focus)
                Circle()
                    .fill(done ? Color.red : Color.red.opacity(0.18))
                    .frame(width: 8, height: 8)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button { m.toggle() } label: {
                Text(m.running ? "Pause" : "Start").frame(width: 70)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .tint(tint)
            Button("Skip") { m.skip() }
            Button("Reset") { m.reset() }
        }
        .controlSize(.large)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in urls.forEach { PomodoroModel.shared.handle(url: $0) } }
    }
}

@main
struct PomodoroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = PomodoroModel.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environmentObject(model)
        } label: {
            Text(model.menuTitle).monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}
