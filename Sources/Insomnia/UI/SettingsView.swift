import AppKit
import ServiceManagement
import SwiftUI

/// The settings window (spec 10). Every change is written straight through
/// `manager.config` to config.json.
struct SettingsView: View {
    let manager: SessionManager
    let secrets: any HotspotSecretStore
    let locationPermission: LocationPermission

    @State private var chargingDuration = ""
    @State private var newFreezeBundle = ""
    @State private var newAgentBundle = ""
    @State private var newTmuxTarget = ""
    @State private var hotspotPassword = ""
    @State private var hotspotSaved = false
    @State private var loginItemError: String?
    /// Names of the apps the automatic lid-close scope would freeze right
    /// now (the freeze list excluded); refreshed on appear and toggle.
    @State private var wouldFreeze: [String] = []

    var body: some View {
        Form {
            chargingSection
            lidSection
            agentSection
            powerSection
            networkSection
            appSection
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 560, idealHeight: 720)
        .onAppear {
            hotspotPassword = (try? secrets.load()) ?? ""
            refreshWouldFreeze()
        }
        // The preview depends on the toggle, both lists and what is running:
        // recompute on any config change and whenever an app launches or quits.
        .onChange(of: manager.config) { refreshWouldFreeze() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in refreshWouldFreeze() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in refreshWouldFreeze() }
    }

    // MARK: Bindings

    private func bind<T>(_ keyPath: WritableKeyPath<Config, T>) -> Binding<T> {
        Binding(
            get: { manager.config[keyPath: keyPath] },
            set: { value in update { $0[keyPath: keyPath] = value } }
        )
    }

    private func update(_ change: (inout Config) -> Void) {
        manager.updateConfig(change)
    }

    // MARK: Sections

    private var chargingSection: some View {
        Section {
            Toggle(StatusMenu.chargingTitle, isOn: bind(\.startOnACPower))
            LabeledContent("Automatic session duration") {
                HStack {
                    TextField("Automatic session duration in hours", text: $chargingDuration, prompt: Text(chargingDurationLabel))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .onSubmit(saveChargingDuration)
                    Text("hours")
                        .foregroundStyle(.secondary)
                    Button("Set", action: saveChargingDuration)
                        .disabled(parsedChargingDuration == nil)
                }
            }
        } header: {
            Text("Charging automation")
        } footer: {
            Text("Connecting power starts a timer when Insomnia is idle. Disconnecting power ends that timer.")
        }
    }

    private var chargingDurationLabel: String {
        let duration = SessionMath.clamp(manager.config.acSessionDuration, maxDuration: manager.config.maxDuration)
        return (duration / 3600).formatted(.number.grouping(.never).precision(.fractionLength(0...4)))
    }

    private var parsedChargingDuration: TimeInterval? {
        guard let duration = DurationParser.seconds(fromHours: chargingDuration),
              duration == SessionMath.clamp(duration, maxDuration: manager.config.maxDuration) else { return nil }
        return duration
    }

    private func saveChargingDuration() {
        guard let duration = parsedChargingDuration else { return }
        update { $0.acSessionDuration = duration }
        if manager.config.acSessionDuration == duration { chargingDuration = "" }
    }

    private var lidSection: some View {
        Section {
            Toggle("Turn off the display and keyboard backlight", isOn: bind(\.darkenDisplayOnLidClose))
            bundleList(
                title: "Freeze while the lid is closed",
                items: manager.config.freezeList,
                newValue: $newFreezeBundle,
                add: { id in update { if !$0.freezeList.contains(id) { $0.freezeList.append(id) } } },
                remove: { id in update { $0.freezeList.removeAll { $0 == id } } }
            )
            Toggle("Freeze every other app while the lid is closed", isOn: bind(\.freezeAllApps))
            Text(wouldFreezeText)
                .font(.callout)
                .foregroundStyle(.secondary)
            Toggle("Pause Docker Desktop when no containers are running", isOn: bind(\.dockerRule))
            Toggle("Mute audio on lid close", isOn: bind(\.muteOnLidClose))
            Toggle("Low Power Mode while the lid is closed", isOn: bind(\.lowPowerOnLidClose))
                // A floor input: apply it now if the lid is already closed.
                .onChange(of: manager.config.lowPowerOnLidClose) { manager.services?.reevaluateFloors() }
        } header: {
            Text("Lid-close actions")
        } footer: {
            Text("Every Dock app that is not an agent app, an Apple app, Docker Desktop or a built-in protected app (editors, AI apps, Tailscale, local model servers) is stopped with SIGSTOP and resumed when the lid opens. Apps on the list above are always frozen; agent apps never are. The display brightness and keyboard backlight are saved, set to zero and restored when the lid opens. If Insomnia is not running when you open the lid, press the brightness-up key.")
        }
    }

    private var agentSection: some View {
        Section {
            bundleList(
                title: "Never throttle or freeze",
                items: manager.config.agentList,
                newValue: $newAgentBundle,
                add: { id in update { if !$0.agentList.contains(id) { $0.agentList.append(id) } } },
                remove: { id in update { $0.agentList.removeAll { $0 == id } } }
            )
        } header: {
            Text("Agent apps")
        } footer: {
            Text("Agent apps are never frozen or throttled. Editors, AI apps, terminals, agent-driven browsers, Tailscale and local model servers are also protected from the automatic lid-close scope even when they are not listed here; adding one to the freeze list above overrides that.")
        }
    }

    private var wouldFreezeText: String {
        wouldFreeze.isEmpty ? "Would freeze now: nothing else" : "Would freeze now: \(wouldFreeze.joined(separator: ", "))"
    }

    /// Same planner as the lid-close action, over the apps running now.
    private func refreshWouldFreeze() {
        let selfId = Bundle.main.bundleIdentifier ?? Paths.bundleIdentifier
        wouldFreeze = FreezePlanner.automaticCandidates(config: manager.config, apps: Freezer.runningApps(), selfBundleId: selfId).map(\.name)
    }

    private var powerSection: some View {
        Section("Battery and thermal") {
            Stepper(value: bind(\.lowPowerFloor), in: 0...100, step: 5) {
                LabeledContent("Low Power Mode below", value: "\(manager.config.lowPowerFloor)%")
            }
            Stepper(value: bind(\.endFloor), in: 0...100, step: 5) {
                LabeledContent("End session below", value: "\(manager.config.endFloor)%")
            }
            Toggle("Thermal rules (Low Power Mode when hot, end when critical)", isOn: bind(\.thermalRules))
        }
    }

    private var networkSection: some View {
        Section {
            TextField("Hotspot SSID", text: bind(\.hotspotSSID))
            HStack {
                SecureField("Hotspot password", text: $hotspotPassword)
                    .onSubmit(savePassword)
                Button(hotspotSaved ? "Saved" : "Save", action: savePassword)
                    .disabled(hotspotPassword.isEmpty)
            }
            HStack {
                Text("Location: \(locationPermission.statusDescription)")
                    .foregroundStyle(.secondary)
                Spacer()
                if locationPermission.isDenied {
                    Button("Open Location Services") {
                        locationPermission.openLocationServicesSettings()
                    }
                }
            }
            Stepper(value: nudgeSeconds, in: 10...900, step: 10) {
                LabeledContent("Nudge tmux after", value: "\(Int(manager.config.nudgeThreshold)) s offline")
            }
            ForEach(manager.config.tmuxTargets, id: \.self) { t in
                HStack {
                    Text(t).font(.system(.body, design: .monospaced))
                    Spacer()
                    removeButton {
                        update { $0.tmuxTargets.removeAll { $0 == t } }
                    }
                }
            }
            HStack {
                TextField("tmux target (session:window.pane)", text: $newTmuxTarget)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTmuxTarget)
                Button("Add", action: addTmuxTarget)
                    .disabled(newTmuxTarget.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Network failover")
        } footer: {
            Text("The password is kept in the login keychain. Location permission lets macOS reveal Wi-Fi network names and find the configured hotspot.")
        }
    }

    private var nudgeSeconds: Binding<Int> {
        Binding(
            get: { Int(manager.config.nudgeThreshold) },
            set: { seconds in update { $0.nudgeThreshold = TimeInterval(seconds) } }
        )
    }

    private func savePassword() {
        if !manager.config.hotspotSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            locationPermission.requestWhenInUse()
        }
        do {
            if hotspotPassword.isEmpty {
                try secrets.delete()
            } else {
                try secrets.save(hotspotPassword)
            }
            hotspotSaved = true
        } catch {
            Log.error("could not save hotspot password: \(error.localizedDescription)")
        }
    }

    private func addTmuxTarget() {
        let t = newTmuxTarget.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        update { if !$0.tmuxTargets.contains(t) { $0.tmuxTargets.append(t) } }
        newTmuxTarget = ""
    }

    private var appSection: some View {
        Section("App") {
            Toggle("Launch at login", isOn: launchAtLogin)
            if let loginItemError {
                Text(loginItemError).font(.caption).foregroundStyle(.red)
            }
            LabeledContent("Config") {
                Text(manager.paths.configFile.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { manager.config.launchAtLogin },
            set: { on in
                do {
                    if on {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    loginItemError = nil
                    // Persist only what macOS actually applied.
                    update { $0.launchAtLogin = on }
                } catch {
                    loginItemError = "Login item: \(error.localizedDescription)"
                    Log.error("launch at login \(on ? "register" : "unregister") failed: \(error.localizedDescription)")
                }
            }
        )
    }

    // MARK: Bundle id lists

    private func bundleList(
        title: String,
        items: [String],
        newValue: Binding<String>,
        add: @escaping (String) -> Void,
        remove: @escaping (String) -> Void
    ) -> some View {
        Group {
            Text(title).font(.headline)
            ForEach(items, id: \.self) { id in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(RunningApps.displayName(for: id))
                        Text(id).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    removeButton { remove(id) }
                }
            }
            HStack {
                TextField("Bundle identifier", text: newValue)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let v = newValue.wrappedValue.trimmingCharacters(in: .whitespaces)
                        guard !v.isEmpty else { return }
                        add(v)
                        newValue.wrappedValue = ""
                    }
                Button("Add") {
                    let v = newValue.wrappedValue.trimmingCharacters(in: .whitespaces)
                    guard !v.isEmpty else { return }
                    add(v)
                    newValue.wrappedValue = ""
                }
                .disabled(newValue.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
                Menu("Add running app…") {
                    let apps = RunningApps.candidates(excluding: items)
                    if apps.isEmpty {
                        Text("No other apps running")
                    }
                    ForEach(apps, id: \.bundleID) { app in
                        Button(app.name) { add(app.bundleID) }
                    }
                }
                .fixedSize()
            }
        }
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Remove")
    }
}

/// Running apps offered by "Add running app…": everything with a bundle id
/// that is not Apple's own.
@MainActor
enum RunningApps {
    struct Entry: Hashable {
        let bundleID: String
        let name: String
    }

    static func candidates(excluding: [String]) -> [Entry] {
        let me = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        var out: [Entry] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, !id.hasPrefix("com.apple."), id != me,
                  app.activationPolicy != .prohibited,
                  !excluding.contains(id), !seen.contains(id) else { continue }
            seen.insert(id)
            out.append(Entry(bundleID: id, name: app.localizedName ?? id))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Name of a running app for a bundle id, or the last path component.
    static func displayName(for bundleID: String) -> String {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
           let name = app.localizedName {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }
}
