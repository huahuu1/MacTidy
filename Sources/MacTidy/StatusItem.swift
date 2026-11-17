import AppKit
import Combine
import SwiftUI

/// Ô số liệu trên thanh menu, vẽ chữ trực tiếp (vector, như chữ hệ thống) thay vì đưa ảnh cho MenuBarExtra.
/// Ảnh bitmap làm chữ mềm và mảnh; MenuBarExtra còn dễ gây vòng lặp cập nhật.
@MainActor
final class StatusItemController: NSObject {
    static let shared = StatusItemController()

    private var item: NSStatusItem?
    private var strip: StripView?
    private var panel: StatusPanel?
    private var bag: Set<AnyCancellable> = []
    private var clickMonitor: Any?
    private var pending = false

    func install() {
        guard item == nil else { return }
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        it.autosaveName = "MacTidyStats"
        guard let button = it.button else { return }
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        let v = StripView(frame: button.bounds)
        v.autoresizingMask = [.width, .height]
        button.addSubview(v)
        item = it
        strip = v

        // Cập nhật khi số liệu hoặc tuỳ chọn đổi (gộp lại một lần mỗi vòng chạy)
        LiveCPU.shared.objectWillChange.sink { [weak self] in self?.scheduleUpdate() }.store(in: &bag)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in self?.scheduleUpdate() }.store(in: &bag)
        update()
    }

    private func scheduleUpdate() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            self?.pending = false
            self?.update()
        }
    }

    private func update() {
        guard let strip, let item else { return }
        strip.data = StripData.current()
        let w = strip.data.width
        if abs(item.length - w) > 0.5 { item.length = w }
        item.button?.setAccessibilityLabel(strip.data.accessibility)
        strip.needsDisplay = true
    }

    // MARK: - Popup

    @objc private func clicked() {
        if let p = panel, p.isVisible { closePanel() } else { openPanel() }
    }

    func openPanel() {
        guard let button = item?.button, let bw = button.window else { return }
        let p = panel ?? makePanel()
        panel = p
        let anchor = bw.convertToScreen(button.convert(button.bounds, to: nil))
        p.anchor = anchor
        p.reposition()
        p.makeKeyAndOrderFront(nil)
        SystemMonitor.shared.popoverVisible = true
        // Bấm ra ngoài thì đóng
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }
    }

    func closePanel() {
        panel?.orderOut(nil)
        SystemMonitor.shared.popoverVisible = false
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    private func makePanel() -> StatusPanel {
        let root = MenuBarView()
            .environmentObject(SystemMonitor.shared)
            .environmentObject(Nav.shared)
            .environmentObject(Cleaner.shared)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        let hc = NSHostingController(rootView: AnyView(root))
        hc.sizingOptions = [.preferredContentSize]
        let p = StatusPanel(contentRect: NSRect(x: 0, y: 0, width: 370, height: 500),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.contentViewController = hc
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.onResignKey = { [weak self] in self?.closePanel() }
        return p
    }
}

/// Bảng treo dưới thanh menu (giống popup của MenuBarExtra), luôn giữ mép trên sát thanh menu khi đổi kích thước.
final class StatusPanel: NSPanel {
    var anchor: NSRect = .zero
    var onResignKey: (() -> Void)?
    override var canBecomeKey: Bool { true }

    override func setContentSize(_ size: NSSize) {
        super.setContentSize(size)
        reposition()
    }

    func reposition() {
        guard anchor != .zero else { return }
        let size = frame.size
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main
        let vis = screen?.visibleFrame ?? .zero
        var x = anchor.midX - size.width / 2
        x = min(max(x, vis.minX + 6), vis.maxX - size.width - 6)
        let y = anchor.minY - size.height - 5
        setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

// MARK: - Dữ liệu + vẽ

/// Ảnh chụp số liệu cần vẽ; tính sẵn độ rộng.
struct StripData: Equatable {
    var cpu = 0, mem = 0
    var cpuTemp: Int?, gpuTemp: Int?
    var netIn = "", netOut = ""
    var hot = false
    var showTemp = true, showCPU = true, showRAM = true, showNet = false, showBattery = true
    var battery: BatteryInfo?

    static let small = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    static let label = NSFont.systemFont(ofSize: 8, weight: .semibold)
    static let value = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .bold)
    static let net = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    static let gap: CGFloat = 8

    @MainActor static func current() -> StripData {
        let L = LiveCPU.shared, d = UserDefaults.standard
        func flag(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) as? Bool ?? def }
        return StripData(cpu: min(100, Int(L.cpu.rounded())), mem: min(100, Int(L.memPercent.rounded())),
                         cpuTemp: L.cpuTemp.map { Int($0.rounded()) }, gpuTemp: L.gpuTemp.map { Int($0.rounded()) },
                         netIn: fmtSpeed(L.netIn), netOut: fmtSpeed(L.netOut),
                         hot: L.thermal == .serious || L.thermal == .critical,
                         showTemp: flag(MenuBarPrefs.temp, true), showCPU: flag(MenuBarPrefs.cpu, true),
                         showRAM: flag(MenuBarPrefs.ram, true), showNet: flag(MenuBarPrefs.net, false),
                         showBattery: flag(MenuBarPrefs.battery, true), battery: L.battery)
    }

    static func w(_ s: String, _ f: NSFont) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: f]).width) }

    var tempW: CGFloat { Self.w("100°", Self.small) }
    var blockW: CGFloat { max(Self.w("100%", Self.value), Self.w("CPU", Self.label)) }
    var netW: CGFloat { Self.w("999 KB/s ↑", Self.net) }
    var batTextW: CGFloat { max(Self.w("100%", Self.small), Self.w("10:00", Self.small)) }
    var batW: CGFloat { batTextW + 5 + 24 + 2 }

    var columns: [CGFloat] {
        var c: [CGFloat] = []
        if hot { c.append(14) }
        if showTemp { c.append(tempW) }
        if showCPU { c.append(blockW) }
        if showRAM { c.append(blockW) }
        if showNet { c.append(netW) }
        if showBattery, battery != nil { c.append(batW) }
        if c.isEmpty { c.append(18) }
        return c
    }
    var width: CGFloat { columns.reduce(0, +) + Self.gap * CGFloat(max(0, columns.count - 1)) + 8 }

    var accessibility: String { "CPU \(cpu)%, RAM \(mem)%" + (battery.map { String(localized: ", pin \($0.level)%") } ?? "") }
}

/// View vẽ chữ trực tiếp trong nút của thanh menu.
final class StripView: NSView {
    var data = StripData()
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }    // để nút bên dưới nhận click

    override func draw(_ dirty: NSRect) {
        let color = NSColor.labelColor          // theo giao diện thanh menu (sáng/tối)
        let h = bounds.height
        let mid = (h / 2).rounded()
        func text(_ s: String, _ f: NSFont, x: CGFloat, baselineFromMid dy: CGFloat, right: CGFloat? = nil, alpha: CGFloat = 1) {
            let a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: color.withAlphaComponent(alpha)]
            let size = (s as NSString).size(withAttributes: a)
            let px = right.map { $0 - size.width } ?? x
            // Đặt đường chân chữ (baseline) ở mid + dy, làm tròn theo điểm ảnh để chữ nét.
            // draw(at:) nhận góc dưới của dòng chữ = baseline + descender (descender là số âm).
            let baseline = (mid + dy).rounded()
            (s as NSString).draw(at: NSPoint(x: px.rounded(), y: baseline + f.descender), withAttributes: a)
        }
        var x: CGFloat = 4
        let gap = StripData.gap
        let deg: (Int?) -> String = { $0.map { "\($0)°" } ?? "—" }

        if data.hot, let flame = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold).applying(.init(paletteColors: [color]))) {
            flame.draw(in: NSRect(x: x, y: ((h - flame.size.height) / 2).rounded(), width: flame.size.width, height: flame.size.height))
            x += 14 + gap
        }
        if data.showTemp {
            let w = data.tempW
            text(deg(data.cpuTemp), StripData.small, x: x, baselineFromMid: 1, right: x + w)
            text(deg(data.gpuTemp), StripData.small, x: x, baselineFromMid: -10, right: x + w)
            x += w + gap
        }
        func block(_ name: String, _ v: Int) {
            text(name, StripData.label, x: x, baselineFromMid: 2.5, alpha: 0.85)
            text("\(v)%", StripData.value, x: x, baselineFromMid: -10)
            x += data.blockW + gap
        }
        if data.showCPU { block("CPU", data.cpu) }
        if data.showRAM { block("RAM", data.mem) }
        if data.showNet {
            let w = data.netW
            text("\(data.netOut) ↑", StripData.net, x: x, baselineFromMid: 1.5, right: x + w)
            text("\(data.netIn) ↓", StripData.net, x: x, baselineFromMid: -9.5, right: x + w)
            x += w + gap
        }
        if data.showBattery, let b = data.battery {
            let tw = data.batTextW
            let bottom = b.shortTime
            if bottom.isEmpty {
                text("\(b.level)%", StripData.small, x: x, baselineFromMid: -4, right: x + tw)
            } else {
                text("\(b.level)%", StripData.small, x: x, baselineFromMid: 1, right: x + tw)
                text(bottom, StripData.small, x: x, baselineFromMid: -10, right: x + tw)
            }
            drawBattery(b, x: x + tw + 5, color: color)
            x += data.batW + gap
        }
        if data.columns == [18], let g = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular).applying(.init(paletteColors: [color]))) {
            g.draw(in: NSRect(x: x, y: ((h - g.size.height) / 2).rounded(), width: g.size.width, height: g.size.height))
        }
    }

    private func drawBattery(_ b: BatteryInfo, x: CGFloat, color: NSColor) {
        let bodyW: CGFloat = 24, bodyH: CGFloat = 11.5
        let y = ((bounds.height - bodyH) / 2).rounded() + 0.5
        let outline = NSBezierPath(roundedRect: NSRect(x: x + 0.5, y: y, width: bodyW - 1, height: bodyH - 1), xRadius: 3, yRadius: 3)
        color.withAlphaComponent(0.45).setStroke()
        outline.lineWidth = 1
        outline.stroke()
        color.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: NSRect(x: x + bodyW + 0.5, y: y + 3, width: 2, height: bodyH - 7), xRadius: 1, yRadius: 1).fill()
        let level = CGFloat(b.level) / 100
        let inner = NSRect(x: x + 2, y: y + 1.5, width: max(1.5, (bodyW - 4) * level), height: bodyH - 4)
        (b.level <= 20 && !b.external ? NSColor.systemRed : color).setFill()
        NSBezierPath(roundedRect: inner, xRadius: 1.5, yRadius: 1.5).fill()
        if b.external, let sym = NSImage(systemSymbolName: b.charging ? "bolt.fill" : "powerplug.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8.5, weight: .black)) {
            let r = NSRect(x: (x + (bodyW - sym.size.width) / 2).rounded(), y: (y + (bodyH - 1 - sym.size.height) / 2).rounded(),
                           width: sym.size.width, height: sym.size.height)
            sym.draw(in: r, from: .zero, operation: .destinationOut, fraction: 1)   // khoét ký hiệu sạc ra khỏi phần đã tô
        }
    }
}
