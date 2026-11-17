import AppKit
import UserNotifications

/// Gửi thông báo macOS khi máy nóng hoặc một app dùng nhiều CPU kéo dài.
@MainActor
final class HeatAlert: NSObject, UNUserNotificationCenterDelegate {
    static let shared = HeatAlert()
    static let key = "heatAlertEnabled"

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.key) }
    }
    /// Mở cửa sổ chính (gán từ SwiftUI, nơi có openWindow).
    var openMain: (() -> Void)?

    private var lastSent = Date.distantPast
    private var hogTicks: [String: Int] = [:]
    private let hogLimit = 40          // 40 lần × 3 giây = 2 phút
    private let quiet: TimeInterval = 15 * 60

    func setup() {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func check(apps: [AppUsage], thermal: ProcessInfo.ThermalState) {
        var ticks: [String: Int] = [:]
        for a in apps where a.cpu >= 80 && a.bundlePath != nil { ticks[a.id] = (hogTicks[a.id] ?? 0) + 1 }
        hogTicks = ticks
        guard enabled, Date().timeIntervalSince(lastSent) > quiet else { return }

        if thermal == .serious || thermal == .critical {
            let top = apps.filter { $0.bundlePath != nil }.max { $0.cpu < $1.cpu }
            send(Thermal(state: thermal).title,
                 top.map { String(localized: "\($0.name) đang dùng \(Int($0.cpu))% CPU. Bấm để xem app nào làm máy nóng.") }
                    ?? String(localized: "macOS đang giảm tốc CPU để hạ nhiệt."))
        } else if let id = hogTicks.first(where: { $0.value >= hogLimit })?.key,
                  let a = apps.first(where: { $0.id == id }) {
            send(String(localized: "\(a.name) dùng nhiều CPU"), String(localized: "\(Int(a.cpu))% CPU liên tục hơn 2 phút. Bấm để xem."))
            hogTicks[id] = 0
        }
    }

    private func send(_ title: String, _ body: String) {
        lastSent = Date()
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        Task { @MainActor in
            Nav.shared.page = .cpu
            NSApp.setActivationPolicy(.regular)
            HeatAlert.shared.openMain?()
            NSApp.activate(ignoringOtherApps: true)
            done()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}
