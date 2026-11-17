import AppKit
import ServiceManagement
import SwiftUI

@main
struct MacTidyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var monitor = SystemMonitor.shared
    @StateObject private var nav = Nav.shared
    @StateObject private var cleaner = Cleaner.shared
    @StateObject private var docker = DockerModel()

    var body: some Scene {
        Window("MacTidy", id: "main") {
            MainView()
                .environmentObject(monitor)
                .environmentObject(nav)
                .environmentObject(cleaner)
                .environmentObject(docker)
                .onAppear { NSApp.setActivationPolicy(.regular) }
                .background(OpenWindowCatcher())
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1000, height: 700)
        .commands {
            CommandMenu("Đi tới") {
                ForEach(Array(Page.allCases.prefix(9).enumerated()), id: \.offset) { i, p in
                    Button(p.title) { withAnimation { Nav.shared.page = p } }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
            }
        }

    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            HeatAlert.shared.setup()
            HeatAlert.shared.openMain = { AppOpener.openMain() }
            SystemMonitor.shared.start()
            StatusItemController.shared.install()
            MenuBarHider.shared.start()
            if let file = ProcessInfo.processInfo.environment["MACTIDY_HIDER_TEST"] {
                let h = MenuBarHider.shared
                var log = ""
                try? await Task.sleep(nanoseconds: 2_500_000_000); log += "== sau khi cài\n" + h.debugFrames()
                h.collapse(); try? await Task.sleep(nanoseconds: 800_000_000); log += "== thu gọn\n" + h.debugFrames()
                h.expand(); try? await Task.sleep(nanoseconds: 800_000_000); log += "== mở rộng\n" + h.debugFrames()
                try? log.write(toFile: file, atomically: true, encoding: .utf8)
            }
            // Dùng khi đo hiệu năng: mở thẳng một trang, hoặc bắt đầu quét ngay
            let env = ProcessInfo.processInfo.environment
            if let p = env["MACTIDY_START_PAGE"].flatMap(Page.init(rawValue:)) { Nav.shared.page = p }
            if env["MACTIDY_START_SCAN"] != nil { Cleaner.shared.scan() }
            if env["MACTIDY_NO_WINDOW"] != nil {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                NSApp.windows.first { $0.title == "MacTidy" }?.close()
            }
            if let dir = ProcessInfo.processInfo.environment["MACTIDY_SNAPSHOT"] {
                await Snapshot.run(dir: dir)
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Bấm X đóng cửa sổ chính: ẩn icon khỏi Dock, app vẫn chạy trên thanh menu
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { n in
            guard let w = n.object as? NSWindow, w.title == "MacTidy" else { return }
            DispatchQueue.main.async {
                let others = NSApp.windows.contains { $0 !== w && $0.isVisible && $0.title == "MacTidy" }
                if !others { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }
}

/// Ngôn ngữ giao diện. Chữ gốc trong code là tiếng Việt, bản tiếng Anh nằm trong en.lproj.
/// Đổi ngôn ngữ = ghi AppleLanguages riêng cho app rồi mở lại app.
enum AppLanguage {
    static var current: String { Bundle.main.preferredLocalizations.first?.hasPrefix("vi") == true ? "vi" : "en" }
    static var isEnglish: Bool { current == "en" }

    @MainActor static func set(_ lang: String) {
        guard lang != current else { return }
        UserDefaults.standard.set([lang], forKey: "AppleLanguages")
        UserDefaults.standard.synchronize()
        relaunch()
    }

    @MainActor static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }
}

/// Chọn ngôn ngữ. Tên ngôn ngữ luôn viết bằng chính ngôn ngữ đó, không dịch.
struct LanguagePicker: View {
    var body: some View {
        Picker(selection: Binding(get: { AppLanguage.current }, set: { AppLanguage.set($0) })) {
            Text(verbatim: "Tiếng Việt").tag("vi")
            Text(verbatim: "English").tag("en")
        } label: {
            Label { Text(verbatim: "Ngôn ngữ / Language") } icon: { Image(systemName: "globe") }
        }
    }
}

/// Mở cửa sổ chính từ bất kỳ đâu (popup thanh menu, thông báo).
/// Lưu lại lệnh openWindow của SwiftUI khi cửa sổ chính hiện, để mở lại cửa sổ sau khi đã đóng.
struct OpenWindowCatcher: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear.onAppear { AppOpener.openWindowAction = openWindow }
    }
}

@MainActor
enum AppOpener {
    static var openWindowAction: OpenWindowAction?
    static func openMain(page: Page? = nil) {
        if let page { Nav.shared.page = page }
        StatusItemController.shared.closePanel()
        NSApp.setActivationPolicy(.regular)
        if let w = NSApp.windows.first(where: { $0.title == "MacTidy" && $0.canBecomeMain }) {
            w.makeKeyAndOrderFront(nil)
        } else if let action = openWindowAction {
            // Cửa sổ đã đóng: gọi lại lệnh mở cửa sổ đã lưu từ SwiftUI
            action(id: "main")
        } else {
            // Chưa có lệnh đã lưu (app mở mà không hiện cửa sổ): gửi sự kiện "mở lại" (giống bấm icon trên Dock) cho chính app,
            // SwiftUI nhận sự kiện này và tạo lại cửa sổ chính
            let me = NSAppleEventDescriptor(processIdentifier: ProcessInfo.processInfo.processIdentifier)
            let ev = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
                                            targetDescriptor: me, returnID: AEReturnID(kAutoGenerateReturnID),
                                            transactionID: AETransactionID(kAnyTransactionID))
            _ = try? ev.sendEvent(options: [.noReply], timeout: 2)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Các cột trên thanh menu bar, bật/tắt được trong ⚙ của popup.
enum MenuBarPrefs {
    static let temp = "mb.temp", cpu = "mb.cpu", ram = "mb.ram", net = "mb.net", battery = "mb.battery"
}

struct MenuBarLabel: View {
    @ObservedObject var live: LiveCPU
    @AppStorage(MenuBarPrefs.temp) private var showTemp = true
    @AppStorage(MenuBarPrefs.cpu) private var showCPU = true
    @AppStorage(MenuBarPrefs.ram) private var showRAM = true
    @AppStorage(MenuBarPrefs.net) private var showNet = false
    @AppStorage(MenuBarPrefs.battery) private var showBattery = true
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: render())
    }

    /// MenuBarExtra chỉ nhận ảnh hoặc 1 dòng chữ. Ảnh được vẽ bằng chữ vector ngay lúc hiển thị
    /// (NSImage drawingHandler), nên nét như chữ hệ thống ở mọi độ phân giải. Ảnh template:
    /// macOS tự tô trắng hoặc đen theo thanh menu sáng/tối.
    @MainActor private func render() -> NSImage {
        StripRenderer.image(cpu: live.cpu, mem: live.memPercent, cpuTemp: live.cpuTemp, gpuTemp: live.gpuTemp,
                            netIn: live.netIn, netOut: live.netOut,
                            hot: live.thermal == .serious || live.thermal == .critical,
                            showTemp: showTemp, showCPU: showCPU, showRAM: showRAM, showNet: showNet,
                            battery: live.battery, showBattery: showBattery)
    }
}

/// Vẽ dải số trên thanh menu. Mỗi cột có độ rộng cố định (đủ cho "100%", "100°")
/// để số đổi không làm các icon bên cạnh xê dịch và không bị cắt chữ.
enum StripRenderer {
    static let small = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
    static let label = NSFont.systemFont(ofSize: 7.5, weight: .semibold)
    static let value = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
    static let net = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium)

    /// Vẽ sẵn thành ảnh bitmap đúng độ phân giải màn hình (Retina 2x), kích thước tròn điểm ảnh nên chữ nét.
    /// Không dùng NSImage có drawingHandler: thanh menu sẽ tính lại kích thước và vẽ lại liên tục (100% CPU).
    static func rasterize(_ size: NSSize, _ draw: (NSRect) -> Void) -> NSImage {
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return NSImage(size: size) }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: size)
        img.addRepresentation(rep)
        return img
    }

    static func width(_ s: String, _ f: NSFont) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: f]).width) }

    /// Giữ lại ảnh lần trước: chỉ tạo ảnh mới khi chữ hiển thị đổi.
    /// Nếu mỗi lần vẽ lại tạo ảnh mới, SwiftUI và thanh menu sẽ kích nhau vẽ lại liên tục (100% CPU).
    @MainActor private static var cache: (key: String, image: NSImage)?

    @MainActor
    static func image(cpu: Double, mem: Double, cpuTemp: Double?, gpuTemp: Double?, netIn: Double, netOut: Double,
                      hot: Bool, showTemp: Bool, showCPU: Bool, showRAM: Bool, showNet: Bool,
                      battery: BatteryInfo? = nil, showBattery: Bool = false) -> NSImage {
        let deg: (Double?) -> String = { $0.map { "\(Int($0.rounded()))°" } ?? "—" }
        let pct: (Double) -> String = { "\(min(100, Int($0.rounded())))%" }
        let key = [deg(cpuTemp), deg(gpuTemp), pct(cpu), pct(mem), showNet ? fmtSpeed(netIn) : "", showNet ? fmtSpeed(netOut) : "",
                   "\(hot)\(showTemp)\(showCPU)\(showRAM)\(showNet)",
                   showBattery ? (battery.map { "\($0.level)\($0.shortTime)\($0.external)\($0.charging)" } ?? "nobat") : ""].joined(separator: "|")
        if let c = cache, c.key == key { return c.image }
        let img = draw(cpu: cpu, mem: mem, cpuTemp: cpuTemp, gpuTemp: gpuTemp, netIn: netIn, netOut: netOut,
                       hot: hot, showTemp: showTemp, showCPU: showCPU, showRAM: showRAM, showNet: showNet,
                       battery: showBattery ? battery : nil)
        cache = (key, img)
        return img
    }

    private static func draw(cpu: Double, mem: Double, cpuTemp: Double?, gpuTemp: Double?, netIn: Double, netOut: Double,
                             hot: Bool, showTemp: Bool, showCPU: Bool, showRAM: Bool, showNet: Bool,
                             battery: BatteryInfo?) -> NSImage {
        let h: CGFloat = 22, gap: CGFloat = 7
        let deg: (Double?) -> String = { $0.map { "\(Int($0.rounded()))°" } ?? "—" }
        let pct: (Double) -> String = { "\(min(100, Int($0.rounded())))%" }

        // Mỗi cột: độ rộng + hàm vẽ tại x
        var cols: [(CGFloat, (CGFloat) -> Void)] = []
        func draw(_ s: String, _ f: NSFont, x: CGFloat, y: CGFloat, right: CGFloat? = nil) {
            let a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: NSColor.black]
            let w = (s as NSString).size(withAttributes: a).width
            (s as NSString).draw(at: NSPoint(x: right.map { $0 - w } ?? x, y: y), withAttributes: a)
        }
        if hot, let flame = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)) {
            cols.append((flame.size.width, { x in flame.draw(in: NSRect(x: x, y: (h - flame.size.height) / 2, width: flame.size.width, height: flame.size.height)) }))
        }
        if showTemp {
            let w = width("100°", small)
            let top = deg(cpuTemp), bottom = deg(gpuTemp)
            cols.append((w, { x in
                draw(top, small, x: x, y: 10.5, right: x + w)
                draw(bottom, small, x: x, y: 0, right: x + w)
            }))
        }
        func block(_ name: String, _ v: String) {
            let w = max(width("100%", value), width(name, label))
            cols.append((w, { x in
                draw(name, label, x: x, y: 12.5)
                draw(v, value, x: x, y: -1)
            }))
        }
        if showCPU { block("CPU", pct(cpu)) }
        if showRAM { block("RAM", pct(mem)) }
        if showNet {
            let w = width("999 KB/s ↑", net)
            let up = "\(fmtSpeed(netOut)) ↑", down = "\(fmtSpeed(netIn)) ↓"
            cols.append((w, { x in
                draw(up, net, x: x, y: 11, right: x + w)
                draw(down, net, x: x, y: 0.5, right: x + w)
            }))
        }
        if let battery {
            // Cột pin: % và thời gian còn lại, kèm hình cục pin (vẽ sẵn ở BatteryStrip)
            let bimg = BatteryStrip.draw(battery)
            cols.append((bimg.size.width, { x in bimg.draw(in: NSRect(x: x, y: 0, width: bimg.size.width, height: bimg.size.height)) }))
        }
        if cols.isEmpty, let g = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) {
            cols.append((g.size.width, { x in g.draw(in: NSRect(x: x, y: (h - g.size.height) / 2, width: g.size.width, height: g.size.height)) }))
        }

        let total = cols.reduce(0) { $0 + $1.0 } + gap * CGFloat(max(0, cols.count - 1)) + 2
        let img = rasterize(NSSize(width: ceil(total), height: h)) { _ in
            var x: CGFloat = 1
            for (w, d) in cols { d(x); x += w + gap }
        }
        img.isTemplate = true
        img.accessibilityDescription = "CPU \(pct(cpu)), RAM \(pct(mem))"
        return img
    }
}

struct StatusStrip: View {
    let cpu: Double, mem: Double
    let cpuTemp: Double?, gpuTemp: Double?
    let netIn: Double, netOut: Double
    let hot: Bool
    let showTemp: Bool, showCPU: Bool, showRAM: Bool, showNet: Bool

    var body: some View {
        HStack(spacing: 8) {
            if hot { Image(systemName: "flame.fill").font(.system(size: 12)) }
            if showTemp {
                VStack(alignment: .trailing, spacing: -1) {
                    Text(deg(cpuTemp)).help("CPU")
                    Text(deg(gpuTemp)).help("GPU")
                }
                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                .frame(width: 24, alignment: .trailing)
            }
            if showCPU { block("CPU", "\(Int(cpu.rounded()))%") }
            if showRAM { block("RAM", "\(Int(mem.rounded()))%") }
            if showNet {
                VStack(alignment: .trailing, spacing: -1) {
                    Text("\(fmtSpeed(netOut)) ↑")
                    Text("\(fmtSpeed(netIn)) ↓")
                }
                .font(.system(size: 8.5, weight: .medium).monospacedDigit())
                .frame(width: 66, alignment: .trailing)
            }
            if !(showTemp || showCPU || showRAM || showNet) {
                Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 13))
            }
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 1)
        .frame(height: 22)
        .fixedSize()
    }

    private func deg(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))°" } ?? "—" }

    private func block(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: -2) {
            Text(label).font(.system(size: 7.5, weight: .semibold))
            Text(value).font(.system(size: 12, weight: .bold).monospacedDigit())
        }
        .frame(width: 32, alignment: .leading)
    }
}

struct MenuBarView: View {
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var cleaner: Cleaner
    @Environment(\.openWindow) private var openWindow
    @State private var quitTarget: AppUsage?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var heatAlert = HeatAlert.shared.enabled
    @AppStorage(MenuBarPrefs.temp) private var showTemp = true
    @AppStorage(MenuBarPrefs.cpu) private var showCPU = true
    @AppStorage(MenuBarPrefs.ram) private var showRAM = true
    @AppStorage(MenuBarPrefs.net) private var showNet = false
    @AppStorage(MenuBarPrefs.battery) private var showBatteryCol = true
    @AppStorage("mb.popupTab") private var tab = 0

    var body: some View {
        let t = Thermal(state: monitor.thermal)
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $tab) {
                Text("Hệ thống").tag(0)
                Text("Pin").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden()
            if tab == 1 {
                BatteryView(embedded: true)
            } else {
            VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 18) {
                Dial(value: monitor.cpu, label: "CPU", size: 112, line: 10)
                VStack(alignment: .leading, spacing: 10) {
                    Label(t.title, systemImage: t.icon)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    StatBar(title: "RAM", value: fmtGB(monitor.memUsed), fraction: monitor.memPercent / 100, compact: true)
                    StatBar(title: "Swap", value: fmtGB(monitor.swapUsed),
                            fraction: Double(monitor.swapUsed) / Double(max(1, monitor.memTotal)), compact: true)
                    StatBar(title: String(localized: "Ổ trống"), value: fmtBytes(monitor.diskFree), fraction: monitor.diskUsedPercent / 100, compact: true)
                }
            }

            if monitor.temps.cpu != nil || monitor.temps.gpu != nil {
                HStack(spacing: 14) {
                    Label("CPU \(monitor.temps.cpu.map { "\(Int($0.rounded()))°C" } ?? "—")", systemImage: "cpu")
                    Label("GPU \(monitor.temps.gpu.map { "\(Int($0.rounded()))°C" } ?? "—")", systemImage: "rectangle.3.group")
                    if let mx = monitor.temps.cpuMax {
                        Text("nhân nóng nhất \(Int(mx.rounded()))°C").foregroundStyle(mx >= 95 ? Color(hex: 0xFF6B5B) : Theme.text2)
                    }
                    Spacer()
                }
                .font(.caption.monospacedDigit())
            }
            HStack(spacing: 14) {
                Label(fmtSpeed(monitor.netIn), systemImage: "arrow.down").help("Tốc độ tải xuống")
                    .contentTransition(.numericText()).animation(Motion.value, value: monitor.netIn)
                Label(fmtSpeed(monitor.netOut), systemImage: "arrow.up").help("Tốc độ tải lên")
                    .contentTransition(.numericText()).animation(Motion.value, value: monitor.netOut)
                Spacer()
                if let b = monitor.battery {
                    Label(b.charging ? String(localized: "Pin \(b.percent)%, đang sạc")
                          : b.plugged ? String(localized: "Pin \(b.percent)%, cắm sạc") : String(localized: "Pin \(b.percent)%"),
                          systemImage: b.charging ? "battery.100.bolt" : (b.percent > 50 ? "battery.75" : "battery.25"))
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Theme.text2)

            if monitor.thermal == .serious || monitor.thermal == .critical || monitor.swapHigh {
                VStack(alignment: .leading, spacing: 4) {
                    if monitor.thermal == .serious || monitor.thermal == .critical {
                        Text(t.detail)
                    }
                    if monitor.swapHigh {
                        Text("Swap \(fmtGB(monitor.swapUsed)): RAM không đủ, nên tắt bớt app hoặc restart.")
                    }
                }
                .font(.caption)
                .foregroundStyle(Color(hex: 0xF2B544))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0xF2B544).opacity(0.12)))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Đang tốn CPU").font(.subheadline.weight(.semibold)).padding(.horizontal, 8).padding(.bottom, 2)
                ForEach(monitor.byCPU.prefix(6)) { a in
                    AppRow(app: a, compact: true) { quitTarget = $0 }
                }
                .animation(Motion.spring, value: monitor.byCPU.prefix(6).map(\.id))
            }
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.glass))

            }
            }
            HiderSettingsView(onChoose: { open(.menubar) })

            HStack(spacing: 8) {
                pill(String(localized: "Mở MacTidy"), "macwindow") { open(.overview) }
                pill(cleaner.selectedSize > 0 ? String(localized: "Dọn \(fmtBytes(cleaner.selectedSize))") : String(localized: "Dọn rác"), "sparkles", tint: Theme.mint) { open(.clean) }
                Spacer()
                Menu {
                    Toggle("Mở cùng máy", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                    Toggle("Báo khi máy nóng", isOn: Binding(get: { heatAlert }, set: { heatAlert = $0; HeatAlert.shared.enabled = $0 }))
                    Divider()
                    Section("Hiện trên thanh menu") {
                        Toggle("Nhiệt độ CPU và GPU", isOn: $showTemp)
                        Toggle("CPU %", isOn: $showCPU)
                        Toggle("RAM %", isOn: $showRAM)
                        Toggle("Tốc độ mạng", isOn: $showNet)
                        Toggle("Pin", isOn: $showBatteryCol)
                    }
                    Divider()
                    LanguagePicker()
                    Divider()
                    Button("Thoát MacTidy") { NSApp.terminate(nil) }
                } label: { Image(systemName: "gearshape.fill") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(16)
        .frame(width: 370)
        .onAppear { monitor.popoverVisible = true }
        .onDisappear { monitor.popoverVisible = false }
        .foregroundStyle(.white)
        .background(ThermalBackground(state: monitor.thermal))
        .environment(\.colorScheme, .dark)
        .quitConfirm($quitTarget, monitor: monitor)
    }

    private func pill(_ title: String, _ icon: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.callout.weight(.medium))
                .foregroundStyle(tint == nil ? Color.white : Color.black.opacity(0.85))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(tint ?? Color.white.opacity(0.12)))
        }
        .buttonStyle(PressableStyle())
    }

    private func open(_ page: Page) {
        AppOpener.openMain(page: page)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("MacTidy login item: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
