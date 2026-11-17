import AppKit
import IOKit
import SwiftUI

/// Thông tin pin đọc từ AppleSmartBattery (IORegistry), không cần quyền gì thêm.
struct BatteryInfo: Equatable {
    var level = 0                    // %
    var external = false             // đang cắm sạc
    var charging = false
    var fullyCharged = false
    var timeToEmpty: Int?            // phút, nil = chưa tính được
    var timeToFull: Int?
    var cycles = 0
    var designCapacity = 0           // mAh
    var maxCapacity = 0              // mAh, dung lượng tối đa hiện tại (NominalChargeCapacity)
    var currentCapacity = 0          // mAh
    var voltage = 0                  // mV
    var amperage = 0                 // mA, âm = đang xả
    var adapterWatts: Int?
    var adapterVoltage: Int?         // mV
    var adapterCurrent: Int?         // mA (tối đa)
    var systemPowerIn: Int?          // mW, điện máy đang lấy từ củ sạc
    var temperature: Double?         // °C, từ SMC

    var health: Double? { designCapacity > 0 && maxCapacity > 0 ? Double(maxCapacity) / Double(designCapacity) * 100 : nil }
    var batteryWatts: Double { Double(voltage) * Double(amperage) / 1_000_000 }

    /// Dòng thứ 2 trên thanh menu: thời gian còn lại (sạc đầy / dùng pin). Không có thì để trống.
    var shortTime: String {
        if external { return timeToFull.map(Self.hm) ?? "" }
        return timeToEmpty.map(Self.hm) ?? ""
    }

    static func hm(_ m: Int) -> String { "\(m / 60):" + String(format: "%02d", m % 60) }
}

enum BatteryReader {
    static func read() -> BatteryInfo? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return nil }
        let bd = d["BatteryData"] as? [String: Any] ?? [:]
        func int(_ k: String) -> Int? { (d[k] as? Int) ?? (bd[k] as? Int) }
        func time(_ k: String) -> Int? { int(k).flatMap { $0 > 0 && $0 < 65535 ? $0 : nil } }

        var b = BatteryInfo()
        b.level = int("CurrentCapacity") ?? 0
        b.external = d["ExternalConnected"] as? Bool ?? false
        b.charging = d["IsCharging"] as? Bool ?? false
        b.fullyCharged = d["FullyCharged"] as? Bool ?? false
        b.timeToEmpty = time("AvgTimeToEmpty") ?? (b.external ? nil : time("TimeRemaining"))
        b.timeToFull = time("AvgTimeToFull")
        b.cycles = int("CycleCount") ?? 0
        b.designCapacity = int("DesignCapacity") ?? 0
        b.maxCapacity = int("NominalChargeCapacity") ?? int("AppleRawMaxCapacity") ?? 0
        b.currentCapacity = int("AppleRawCurrentCapacity") ?? 0
        b.voltage = int("Voltage") ?? 0
        let ampNum = (d["InstantAmperage"] as? NSNumber) ?? (d["Amperage"] as? NSNumber)
        b.amperage = ampNum.map { Int(Int32(truncatingIfNeeded: $0.int64Value)) } ?? 0   // số âm (đang xả) đôi khi lưu dạng không dấu
        if let a = d["AdapterDetails"] as? [String: Any] {
            b.adapterWatts = a["Watts"] as? Int
            b.adapterVoltage = a["AdapterVoltage"] as? Int
            b.adapterCurrent = a["Current"] as? Int
        }
        if let t = d["PowerTelemetryData"] as? [String: Any] { b.systemPowerIn = t["SystemPowerIn"] as? Int }
        b.temperature = SMCReader.shared.batteryTemp()
        return b
    }
}

// MARK: - Icon pin trên thanh menu

struct BatteryLabel: View {
    @ObservedObject var live: LiveCPU
    var body: some View {
        Image(nsImage: BatteryStrip.image(live.battery))
    }
}

enum BatteryStrip {
    @MainActor private static var cache: (key: String, image: NSImage)?

    /// Chỉ tạo ảnh mới khi chữ hoặc mức pin đổi (tránh vòng lặp vẽ lại).
    @MainActor
    static func image(_ b: BatteryInfo?) -> NSImage {
        let key = b.map { "\($0.level)|\($0.shortTime)|\($0.external)|\($0.charging)" } ?? "none"
        if let c = cache, c.key == key { return c.image }
        let img = draw(b)
        cache = (key, img)
        return img
    }

    static func draw(_ b: BatteryInfo?) -> NSImage {
        let h: CGFloat = 22
        let top = b.map { "\($0.level)%" } ?? "—"
        let bottom = b?.shortTime ?? ""
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
        let textW = max(StripRenderer.width("100%", font), StripRenderer.width("10:00", font))
        let bodyW: CGFloat = 24, bodyH: CGFloat = 11.5, nub: CGFloat = 2
        let total = ceil(textW + 5 + bodyW + nub + 2)
        let img = StripRenderer.rasterize(NSSize(width: total, height: h)) { _ in
            let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            func right(_ s: String, y: CGFloat) {
                let w = (s as NSString).size(withAttributes: a).width
                (s as NSString).draw(at: NSPoint(x: 1 + textW - w, y: y), withAttributes: a)
            }
            if bottom.isEmpty {
                right(top, y: 5)          // chỉ có % thì canh giữa theo chiều dọc
            } else {
                right(top, y: 10.5)
                right(bottom, y: 0)
            }
            // Hình cục pin: viền, phần đã sạc, núm
            let x = 1 + textW + 5, y = (h - bodyH) / 2
            let outline = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: bodyW, height: bodyH), xRadius: 3, yRadius: 3)
            NSColor.black.withAlphaComponent(0.45).setStroke()
            outline.lineWidth = 1
            outline.stroke()
            NSColor.black.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: NSRect(x: x + bodyW + 0.5, y: y + bodyH * 0.3, width: nub, height: bodyH * 0.4), xRadius: 1, yRadius: 1).fill()
            let level = CGFloat(b?.level ?? 0) / 100
            let inner = NSRect(x: x + 1.5, y: y + 1.5, width: max(1.5, (bodyW - 3) * level), height: bodyH - 3)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: inner, xRadius: 1.5, yRadius: 1.5).fill()
            // Ký hiệu sạc: khoét hình tia sét / phích cắm ra khỏi phần đã tô
            if let b, b.external {
                let name = b.charging ? "bolt.fill" : "powerplug.fill"
                if let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 8.5, weight: .black)) {
                    let r = NSRect(x: x + (bodyW - sym.size.width) / 2, y: y + (bodyH - sym.size.height) / 2,
                                   width: sym.size.width, height: sym.size.height)
                    sym.draw(in: r, from: .zero, operation: .destinationOut, fraction: 1)
                }
            }
        }
        img.isTemplate = true
        img.accessibilityDescription = String(localized: "Pin \(top)")
        return img
    }
}

// MARK: - Popup chi tiết pin

struct BatteryView: View {
    var embedded = false
    @EnvironmentObject var monitor: SystemMonitor
    @ObservedObject var live = LiveCPU.shared

    var body: some View {
        let b = live.battery
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Pin", systemImage: "battery.100percent").font(.headline)
                Spacer()
                if let b { Text(b.external ? (b.charging ? "Đang sạc" : "Đang cắm sạc") : "Đang dùng pin")
                    .font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill((b.external ? Theme.mint : Color(hex: 0xF2B544)).opacity(0.2)))
                    .foregroundStyle(b.external ? Theme.mint : Color(hex: 0xF2B544)) }
            }
            if let b {
                BigBattery(level: b.level, charging: b.charging, external: b.external)
                    .frame(maxWidth: .infinity)
                section(String(localized: "Chi tiết")) {
                    row(String(localized: "Mức pin"), "\(b.level)%")
                    row(String(localized: "Nguồn điện"), b.external ? String(localized: "Củ sạc") : String(localized: "Pin"))
                    if b.external {
                        row(String(localized: "Thời gian sạc đầy"), b.fullyCharged || b.level >= 99 ? String(localized: "Đã sạc đầy") : (b.timeToFull.map(BatteryInfo.hm) ?? String(localized: "Đang tính")))
                    } else {
                        row(String(localized: "Dùng được thêm"), b.timeToEmpty.map { BatteryInfo.hm($0) + String(localized: " giờ") } ?? String(localized: "Đang tính"))
                    }
                }
                section(String(localized: "Pin")) {
                    row(String(localized: "Sức khoẻ"), b.health.map { String(format: "%.0f%%", $0) } ?? "—",
                        color: b.health.map { $0 < 80 ? Color(hex: 0xF2B544) : .white })
                    row(String(localized: "Dung lượng"), "\(fmtInt(b.currentCapacity)) / \(fmtInt(b.maxCapacity)) / \(fmtInt(b.designCapacity)) mAh")
                    row(String(localized: "Số lần sạc"), "\(b.cycles)")
                    row(String(localized: "Nhiệt độ"), b.temperature.map { String(format: "%.1f°C", $0) } ?? "—")
                    row(String(localized: "Công suất"), String(format: "%.2f W", abs(b.batteryWatts)))
                    row(String(localized: "Dòng điện"), "\(b.amperage) mA")
                    row(String(localized: "Điện áp"), String(format: "%.2f V", Double(b.voltage) / 1000))
                }
                if b.external {
                    section(String(localized: "Củ sạc")) {
                        row(String(localized: "Đang sạc pin"), b.charging ? String(localized: "Có") : String(localized: "Không"))
                        row(String(localized: "Công suất củ sạc"), b.adapterWatts.map { "\($0) W" } ?? "—")
                        row(String(localized: "Điện áp"), b.adapterVoltage.map { String(format: "%.0f V", Double($0) / 1000) } ?? "—")
                        row(String(localized: "Dòng tối đa"), b.adapterCurrent.map { "\(fmtInt($0)) mA" } ?? "—")
                        row(String(localized: "Máy đang dùng"), b.systemPowerIn.map { String(format: "%.1f W", Double($0) / 1000) } ?? "—")
                    }
                }
                section(String(localized: "Tốn điện nhất (theo CPU)")) {
                    ForEach(monitor.byCPU.prefix(6)) { a in
                        HStack(spacing: 8) {
                            Group {
                                if a.bundlePath != nil { Image(nsImage: IconCache.shared.icon(for: a.bundlePath)).resizable() }
                                else { Image(systemName: "gearshape.fill").resizable().scaledToFit().padding(2).foregroundStyle(Theme.text2) }
                            }
                            .frame(width: 16, height: 16)
                            Text(a.name).lineLimit(1)
                            Spacer()
                            Text(String(format: "%.1f%%", a.cpu)).monospacedDigit().foregroundStyle(Theme.text2)
                        }
                        .font(.callout)
                    }
                }
            } else {
                Text("Máy này không có pin.").foregroundStyle(Theme.text2)
            }
        }
        .modifier(StandalonePopup(enabled: !embedded, thermal: monitor.thermal))
    }

    struct StandalonePopup: ViewModifier {
        let enabled: Bool
        let thermal: ProcessInfo.ThermalState
        func body(content: Content) -> some View {
            if enabled {
                content.padding(16).frame(width: 320).foregroundStyle(.white)
                    .background(ThermalBackground(state: thermal)).environment(\.colorScheme, .dark)
            } else {
                content
            }
        }
    }

    private func fmtInt(_ v: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = ","
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    @ViewBuilder private func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.text2)
            c()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.glass))
    }

    private func row(_ k: String, _ v: String, color: Color? = nil) -> some View {
        HStack {
            Text(k).foregroundStyle(Theme.text2)
            Spacer()
            Text(v).monospacedDigit().foregroundStyle(color ?? .white)
        }
        .font(.callout)
    }
}

/// Cục pin lớn trong popup.
struct BigBattery: View {
    let level: Int
    let charging: Bool
    let external: Bool
    var body: some View {
        let c = level <= 20 ? Color(hex: 0xFF6B5B) : (level <= 40 ? Color(hex: 0xF2B544) : Theme.mint)
        HStack(spacing: 3) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.35), lineWidth: 2)
                GeometryReader { g in
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(c.gradient)
                        .frame(width: max(6, (g.size.width - 8) * CGFloat(level) / 100))
                        .padding(4)
                        .animation(Motion.spring, value: level)
                }
                HStack {
                    Spacer()
                    if external { Image(systemName: charging ? "bolt.fill" : "powerplug.fill").foregroundStyle(.black.opacity(0.7)) }
                    Text("\(level)%").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(.black.opacity(0.75))
                    Spacer()
                }
            }
            .frame(width: 150, height: 64)
            RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.35)).frame(width: 5, height: 22)
        }
    }
}
