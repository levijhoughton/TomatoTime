import SwiftUI
import AppKit
import UserNotifications
import CoreAudio

// MARK: - Varieties and break ideas

struct Variety: Identifiable, Hashable {
    let id: String
    let name: String
    let blurb: String
    let focus: TimeInterval
    let short: TimeInterval
    let long: TimeInterval
    let rounds: Int
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

// MARK: - Model

@MainActor
final class PomodoroModel: ObservableObject {
    enum Phase { case focus, shortBreak, longBreak }

    @Published var variety: Variety {
        didSet {
            UserDefaults.standard.set(variety.id, forKey: "variety")
            reset()
        }
    }
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

    init() {
        let d = UserDefaults.standard
        let saved = d.string(forKey: "variety")
        let v = varieties.first { $0.id == saved } ?? varieties[0]
        variety = v
        remaining = v.focus
        autoContinue = d.object(forKey: "autoContinue") as? Bool ?? true
        pauseOthers = d.object(forKey: "pauseOthers") as? Bool ?? true
        if pauseOthers && !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }

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

    func start() {
        guard !running else { return }
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
    }

    func reset() {
        stopTimer()
        phase = .focus
        round = 1
        remaining = variety.focus
        suggestion = ""
    }

    func skip() {
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
                    ForEach(varieties) { Text($0.name).tag($0) }
                }
                Text(m.variety.blurb).font(.caption).foregroundStyle(.secondary)
                Toggle("Keep going automatically", isOn: $m.autoContinue)
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

@main
struct PomodoroApp: App {
    @StateObject private var model = PomodoroModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environmentObject(model)
        } label: {
            Text(model.menuTitle).monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}
