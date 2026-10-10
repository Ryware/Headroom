import SwiftUI
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.applyDockPolicy()
        Task { @MainActor in DiskMonitor.shared.start() }
#if !APP_STORE
        if Pref.bool("mcpServerEnabled", true) { MCPHTTPServer.shared.start() }
#endif
        // Started by "Open at login": stay in the menu bar instead of popping the window open.
        if Self.launchedAtLogin, Pref.bool("menuBarEnabled", true) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                NSApp.windows.filter { $0.canBecomeMain }.forEach { $0.close() }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
#if !APP_STORE
        MCPHTTPServer.shared.stop()   // drops the session token file
#endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(Pref.bool("menuBarEnabled", true) && Pref.bool("keepRunning", true))
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }

    /// Menu-bar-only mode (no Dock icon) is only offered while the menu bar item is on.
    static func applyDockPolicy() {
        let accessory = Pref.bool("menuBarEnabled", true) && !Pref.bool("showInDock", true)
        NSApp.setActivationPolicy(accessory ? .accessory : .regular)
    }

    private static var launchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == AEEventID(kAEOpenApplication)
            && event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == AEKeyword(keyAELaunchedAsLogInItem)
    }
}

@main
enum HeadroomMain {
    static func main() {
        // `Headroom --mcp` serves the Model Context Protocol on stdio instead of opening the UI.
        if CommandLine.arguments.dropFirst().contains("--mcp") { MCPServer.runStdio() }
        // `headroom <command>` runs one tool from the command line (see HeadroomCLI).
        let argv = Array(CommandLine.arguments.dropFirst())
        if HeadroomCLI.handles(argv) { HeadroomCLI.run(argv) }
        HeadroomApp.main()
    }
}

struct HeadroomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()
    @AppStorage("seenIntroVersion") private var seenIntroVersion = 0
    @AppStorage("menuBarEnabled") private var menuBarEnabled = true
    @AppStorage("menuBarShowsText") private var menuBarShowsText = false
    @State private var showIntro = false
    @State private var introPage = 0

    var body: some Scene {
        WindowGroup("Headroom", id: "main") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 1120, minHeight: 680)
                .background(WindowSizing(minSize: NSSize(width: 1120, height: 680)))
                .sheet(isPresented: $showIntro, onDismiss: { seenIntroVersion = currentIntroVersion }) {
                    IntroView(page: introPage)
                }
                .task { MCPServer.app = state }
                .task {
                    // First launch → full tour; updated app → jump to What's New.
                    try? await Task.sleep(for: .milliseconds(600))
                    if seenIntroVersion == 0 { introPage = 0; showIntro = true }
                    else if seenIntroVersion < currentIntroVersion { introPage = 7; showIntro = true }
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Headroom") {
                    let credits = NSAttributedString(string: "See what's eating your disk. Clean it in one click.\n\nScanning uses getattrlistbulk(2) and fans out across all cores; permanent deletion renames first, then unlinks in parallel.", attributes: [.font: NSFont.systemFont(ofSize: 11)])
                    NSApp.orderFrontStandardAboutPanel(options: [.credits: credits, .applicationName: "Headroom"])
                }
            }
            CommandGroup(replacing: .help) {
                Button("Welcome Tour") { introPage = 0; showIntro = true }
                Button("What's New in Headroom") { introPage = 7; showIntro = true }
            }
            CommandGroup(replacing: .newItem) {
                Button("Scan Folder…") { state.pickFolder() }
                    .keyboardShortcut("o")
                Button("Rescan") { state.rescan() }
                    .keyboardShortcut("r")
                    .disabled(state.rootURL == nil || state.isScanning)
            }
        }

        MenuBarExtra(isInserted: $menuBarEnabled) {
            MenuBarPanel().environmentObject(state)
        } label: {
            MenuBarLabel(showText: menuBarShowsText)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(state)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("menuBarEnabled") private var menuBarEnabled = true
    @AppStorage("menuBarShowsText") private var menuBarShowsText = false
    @AppStorage("keepRunning") private var keepRunning = true
    @AppStorage("showInDock") private var showInDock = true
    @AppStorage("alertsLowEnabled") private var lowEnabled = true
    @AppStorage("alertsLowGB") private var lowGB = 10.0
    @AppStorage("alertsDropEnabled") private var dropEnabled = true
    @AppStorage("alertsDropGB") private var dropGB = 5.0
    @AppStorage("mcpServerEnabled") private var mcpServerEnabled = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Deleting") {
                Picker("Deleting", selection: $state.deleteMode) {
                    ForEach(DeleteMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text("Permanent deletion unlinks every file in parallel (like rimraf) and cannot be undone.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Menu bar") {
                Toggle("Show Headroom in the menu bar", isOn: $menuBarEnabled)
                Toggle("Show free space next to the icon", isOn: $menuBarShowsText).disabled(!menuBarEnabled)
                Toggle("Keep running when the window is closed", isOn: $keepRunning).disabled(!menuBarEnabled)
                Toggle("Show in the Dock", isOn: $showInDock).disabled(!menuBarEnabled)
                Toggle("Open at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {}
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                ))
            }

            Section("Alerts") {
                Toggle("Warn when free space is low", isOn: $lowEnabled)
                Stepper("Below \(Int(lowGB)) GB free", value: $lowGB, in: 1...500, step: 1).disabled(!lowEnabled)
                Toggle("Warn when space drops quickly", isOn: $dropEnabled)
                Stepper("Loss of \(Int(dropGB)) GB within an hour", value: $dropGB, in: 1...200, step: 1).disabled(!dropEnabled)
                Text("Alerts are local notifications. Nothing leaves your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }

#if !APP_STORE
            Section("AI agents") {
                Toggle("Let AI agents work in this window", isOn: $mcpServerEnabled)
                if mcpServerEnabled, let error = MCPHTTPServer.lastError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                Text("Agents such as Codex and Claude Code can use Headroom without setup: the app carries instructions for them. When this is on, they work with the folder shown here and you see their results. They can read scan results and safety advice; the only change they can make is moving items to the Trash.")
                    .font(.caption).foregroundStyle(.secondary)
            }
#endif
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 720)
        .onChange(of: menuBarEnabled) { _, _ in AppDelegate.applyDockPolicy() }
        .onChange(of: showInDock) { _, _ in AppDelegate.applyDockPolicy() }
        .onChange(of: mcpServerEnabled) { _, on in
#if !APP_STORE
            if on { MCPHTTPServer.shared.start() } else { MCPHTTPServer.shared.stop() }
#endif
        }
        .onChange(of: lowEnabled) { _, on in if on { DiskMonitor.shared.requestNotificationAuthorization() } }
        .onChange(of: dropEnabled) { _, on in if on { DiskMonitor.shared.requestNotificationAuthorization() } }
    }
}
