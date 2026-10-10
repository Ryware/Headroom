import Foundation
import AppKit
import UserNotifications

// MARK: - Preferences (shared with @AppStorage in the views)

enum Pref {
    static func bool(_ key: String, _ fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }
    static func double(_ key: String, _ fallback: Double) -> Double {
        UserDefaults.standard.object(forKey: key) as? Double ?? fallback
    }
}

// MARK: - Volume snapshot

enum DiskStatus { case ok, warning, critical }

struct VolumeSnapshot: Equatable {
    let name: String
    let total: Int64
    let free: Int64
    var used: Int64 { total - free }
    var freeFraction: Double { total > 0 ? Double(free) / Double(total) : 0 }

    /// Uses the same "available for important usage" number Finder shows (includes purgeable space).
    static func read(path: String = "/") -> VolumeSnapshot? {
        let url = URL(fileURLWithPath: path)
        guard let v = try? url.resourceValues(forKeys: [
            .volumeNameKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ]), let total = v.volumeTotalCapacity, total > 0 else { return nil }
        let free = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
        return VolumeSnapshot(name: v.volumeName ?? "Startup Disk",
                              total: Int64(total), free: min(Int64(total), max(0, free)))
    }
}

struct FreeSpaceSample: Codable, Identifiable, Equatable {
    var t: Date
    var free: Int64
    var id: Date { t }
}

// MARK: - Monitor

/// Watches free space on the startup disk: feeds the menu bar icon, keeps a 7-day history
/// and posts local notifications. Everything stays on this Mac.
@MainActor
final class DiskMonitor: ObservableObject {
    static let shared = DiskMonitor()

    @Published private(set) var snapshot: VolumeSnapshot?
    @Published private(set) var history: [FreeSpaceSample] = []

    private var timer: Timer?
    private var started = false
    private let router = NotificationRouter()
    private var canNotify: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Free space (GB) below which the icon turns red and a warning is sent.
    var lowGB: Double { max(1, Pref.double("alertsLowGB", 10)) }

    var status: DiskStatus {
        guard let free = snapshot?.free else { return .ok }
        let limit = Int64(lowGB * 1e9)
        if free < limit { return .critical }
        if free < limit * 2 { return .warning }
        return .ok
    }

    func start() {
        guard !started else { return }
        started = true
        history = Self.loadHistory()
        if canNotify {
            UNUserNotificationCenter.current().delegate = router
            if Pref.bool("alertsLowEnabled", true) || Pref.bool("alertsDropEnabled", true) {
                requestNotificationAuthorization()
            }
        }
        refresh()
        let t = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = 10
        timer = t
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard let s = VolumeSnapshot.read() else { return }
        snapshot = s
        record(s)
        evaluateAlerts(s)
    }

    func requestNotificationAuthorization() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: History

    private func record(_ s: VolumeSnapshot) {
        let now = Date()
        var changed = false
        if let last = history.last {
            if now.timeIntervalSince(last.t) >= 300 || abs(last.free - s.free) >= 500_000_000 {
                history.append(.init(t: now, free: s.free)); changed = true
            }
        } else {
            history.append(.init(t: now, free: s.free)); changed = true
        }
        let cutoff = now.addingTimeInterval(-7 * 86_400)
        if let first = history.first, first.t < cutoff {
            history.removeAll { $0.t < cutoff }; changed = true
        }
        if history.count > 4000 { history.removeFirst(history.count - 4000); changed = true }
        if changed { Self.saveHistory(history) }
    }

    /// Change in free space over roughly the last `hours`, if the history is long enough.
    func delta(hours: Double) -> Int64? { Self.delta(in: history, hours: hours) }

    nonisolated static func delta(in history: [FreeSpaceSample], hours: Double) -> Int64? {
        guard let last = history.last, let first = history.first,
              last.t.timeIntervalSince(first.t) >= hours * 3600 * 0.5 else { return nil }
        let target = last.t.addingTimeInterval(-hours * 3600)
        let base = history.min { abs($0.t.timeIntervalSince(target)) < abs($1.t.timeIntervalSince(target)) } ?? first
        return last.free - base.free
    }

    nonisolated private static var historyURL: URL? {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true) else { return nil }
        let folder = dir.appendingPathComponent("Headroom", isDirectory: true)
        // 0.x stored history under the old app name; carry it over once.
        let legacy = dir.appendingPathComponent("DiskTree", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path), FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: folder)
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("free-space-history.json")
    }

    nonisolated static func loadHistory() -> [FreeSpaceSample] {
        guard let url = historyURL, let data = try? Data(contentsOf: url),
              let samples = try? JSONDecoder().decode([FreeSpaceSample].self, from: data) else { return [] }
        return samples
    }

    private static func saveHistory(_ samples: [FreeSpaceSample]) {
        guard let url = historyURL, let data = try? JSONEncoder().encode(samples) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Alerts

    private func evaluateAlerts(_ s: VolumeSnapshot) {
        let d = UserDefaults.standard
        let now = Date()
        let threshold = Int64(lowGB * 1e9)

        if Pref.bool("alertsLowEnabled", true) {
            if s.free < threshold {
                let last = d.object(forKey: "lastLowAlert") as? Date
                if last == nil || now.timeIntervalSince(last!) > 6 * 3600 {
                    notify(id: "low", title: "Low disk space",
                           body: "Only \(s.free.humanBytes) free on \(s.name). Open Headroom to see what is using it.")
                    d.set(now, forKey: "lastLowAlert")
                }
            } else if s.free > threshold * 3 / 2 {
                d.removeObject(forKey: "lastLowAlert")
            }
        }

        if Pref.bool("alertsDropEnabled", true) {
            let recent = history.filter { now.timeIntervalSince($0.t) <= 3600 }
            if let peak = recent.map(\.free).max() {
                let lost = peak - s.free
                if Double(lost) >= Pref.double("alertsDropGB", 5) * 1e9 {
                    let last = d.object(forKey: "lastDropAlert") as? Date
                    if last == nil || now.timeIntervalSince(last!) > 3 * 3600 {
                        notify(id: "drop", title: "Free space is dropping fast",
                               body: "Down \(lost.humanBytes) in the last hour. \(s.free.humanBytes) free now.")
                        d.set(now, forKey: "lastDropAlert")
                    }
                }
            }
        }
    }

    private func notify(id: String, title: String, body: String) {
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

// MARK: - Notification tap → open the main window

final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in AppWindows.showMain() }
        completionHandler()
    }
}

@MainActor
enum AppWindows {
    /// Brings the main window forward, or asks macOS to reopen it if it was closed.
    /// Set by the menu bar views, which live for the whole run and can reach SwiftUI's openWindow.
    static var opener: (() -> Void)?

    static func showMain() {
        // A Dock-less (accessory) app can't take focus; become a regular app first.
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
        let candidates = NSApp.windows.filter { $0.canBecomeMain && !$0.isSheet && !($0 is NSPanel) }
        if let w = candidates.first(where: { $0.title == "Headroom" }) ?? candidates.first {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
            w.orderFrontRegardless()
        } else if let opener {
            opener()
        } else {
            NSWorkspace.shared.open(Bundle.main.bundleURL)
        }
        // Return to menu-bar-only mode afterwards if the user chose no Dock icon.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if Pref.bool("menuBarEnabled", true) && !Pref.bool("showInDock", true) {
                // keep .regular while the window is visible; applyDockPolicy runs on next toggle/launch
            }
        }
    }
}
