import AppKit
import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

// MARK: - Theme: màu nền đi theo nhiệt độ máy

enum Theme {
    static let mint = Color(hex: 0x5EE6B3)
    static let text2 = Color.white.opacity(0.62)
    static let glass = Color.white.opacity(0.07)
    static let hairline = Color.white.opacity(0.09)

    struct Palette { let top: Color; let bottom: Color; let glow: Color }

    static func palette(_ t: ProcessInfo.ThermalState) -> Palette {
        switch t {
        case .fair: Palette(top: Color(hex: 0x6B4A17), bottom: Color(hex: 0x1A1510), glow: Color(hex: 0xF2B544))
        case .serious: Palette(top: Color(hex: 0x7E2A17), bottom: Color(hex: 0x1C0E0B), glow: Color(hex: 0xFF7A45))
        case .critical: Palette(top: Color(hex: 0x951C1C), bottom: Color(hex: 0x200909), glow: Color(hex: 0xFF4D4D))
        default: Palette(top: Color(hex: 0x17566F), bottom: Color(hex: 0x0C1828), glow: Color(hex: 0x3FD0C9))
        }
    }
}

func levelColor(_ pct: Double) -> Color {
    pct >= 85 ? Color(hex: 0xFF6B5B) : pct >= 60 ? Color(hex: 0xF2B544) : Theme.mint
}

struct ThermalBackground: View {
    let state: ProcessInfo.ThermalState
    var body: some View {
        let p = Theme.palette(state)
        ZStack {
            LinearGradient(colors: [p.top, p.bottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [p.glow.opacity(0.32), .clear], center: UnitPoint(x: 0.78, y: 0.05),
                           startRadius: 10, endRadius: 520)
        }
        .animation(.easeInOut(duration: 1.5), value: state)
        .ignoresSafeArea()
    }
}

struct Thermal {
    let state: ProcessInfo.ThermalState
    var title: String {
        switch state {
        case .nominal: String(localized: "Máy đang mát")
        case .fair: String(localized: "Máy hơi ấm")
        case .serious: String(localized: "Máy đang nóng")
        case .critical: String(localized: "Máy rất nóng")
        @unknown default: String(localized: "Không rõ nhiệt độ")
        }
    }
    var detail: String {
        switch state {
        case .nominal: String(localized: "CPU chạy hết tốc độ.")
        case .fair: String(localized: "Quạt bắt đầu chạy. Nên xem app nào đang tốn CPU.")
        case .serious: String(localized: "macOS đang giảm tốc CPU để hạ nhiệt. Tắt bớt app tốn CPU.")
        case .critical: String(localized: "macOS đang giảm tốc CPU mạnh. Tắt app tốn CPU ngay.")
        @unknown default: ""
        }
    }
    var short: String {
        switch state {
        case .nominal: String(localized: "Mát")
        case .fair: String(localized: "Ấm")
        case .serious: String(localized: "Nóng")
        case .critical: String(localized: "Rất nóng")
        @unknown default: "?"
        }
    }
    var color: Color { Theme.palette(state).glow }
    var icon: String { state == .nominal ? "thermometer.low" : state == .fair ? "thermometer.medium" : "flame.fill" }
}

// MARK: - Panel kính mờ

struct Glass<Content: View>: View {
    var radius: CGFloat = 20
    var padding: CGFloat = 18
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.glass))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Theme.hairline))
    }
}

// MARK: - Đồng hồ cung tròn (270°)

struct Dial: View {
    let value: Double          // 0...100
    let label: String
    var size: CGFloat = 220
    var line: CGFloat = 16

    var body: some View {
        ZStack {
            DialArc(fraction: max(0.005, min(1, value / 100)), color: NSColor(levelColor(value)), line: line)
            VStack(spacing: 2) {
                Text("\(Int(value.rounded()))%")
                    .font(.system(size: size * 0.26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(label).font(.system(size: max(11, size * 0.065), weight: .medium)).foregroundStyle(Theme.text2)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Cung tròn 270° của đồng hồ. Vẽ bằng CAShapeLayer: khi giá trị đổi,
/// Core Animation tự chạy hiệu ứng strokeEnd, app không phải vẽ lại từng khung hình.
struct DialArc: NSViewRepresentable {
    let fraction: Double
    let color: NSColor
    let line: CGFloat

    final class Layers { let track = CAShapeLayer(), glow = CAShapeLayer(), arc = CAShapeLayer() }
    func makeCoordinator() -> Layers { Layers() }

    func makeNSView(context: Context) -> LayerView {
        let v = LayerView()
        let L = context.coordinator
        for (l, w) in [(L.track, line), (L.glow, line * 2.2), (L.arc, line)] {
            l.fillColor = nil
            l.lineWidth = w
            l.lineCap = .round
            v.layer!.addSublayer(l)
        }
        L.track.strokeColor = NSColor.white.withAlphaComponent(0.08).cgColor
        L.track.strokeEnd = 0.75
        v.onLayout = { _, b in
            // Bắt đầu ở góc 135° (dưới bên trái), quay theo chiều kim đồng hồ 270°
            let r = min(b.width, b.height) / 2 - line * 1.1
            let path = CGMutablePath()
            path.addArc(center: CGPoint(x: b.midX, y: b.midY), radius: r,
                        startAngle: .pi * 1.25, endAngle: .pi * 1.25 - .pi * 2, clockwise: true)
            for l in [L.track, L.glow, L.arc] { l.frame = b; l.path = path }
        }
        apply(L, animated: false)
        return v
    }

    func updateNSView(_ v: LayerView, context: Context) { apply(context.coordinator, animated: true) }

    private func apply(_ L: Layers, animated: Bool) {
        let end = 0.75 * fraction
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.4 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        L.arc.strokeEnd = end
        L.glow.strokeEnd = end
        L.arc.strokeColor = color.cgColor
        L.glow.strokeColor = color.withAlphaComponent(0.18).cgColor
        CATransaction.commit()
    }
}

/// Thanh ngang có tên và số.
struct StatBar: View {
    let title: String
    let value: String
    let fraction: Double     // 0...1
    var color: Color? = nil
    var compact = false

    var body: some View {
        let c = color ?? levelColor(fraction * 100)
        VStack(alignment: .leading, spacing: compact ? 4 : 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(compact ? .caption : .callout).foregroundStyle(Theme.text2)
                Spacer()
                Text(value).font(.system(compact ? .callout : .title3, design: .rounded).weight(.semibold)).monospacedDigit()
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(c).frame(width: max(4, g.size.width * min(1, max(0, fraction))))
                        .animation(Motion.value, value: fraction)
                }
            }
            .frame(height: compact ? 5 : 7)
        }
    }
}

/// Nút tròn lớn ở giữa màn hình.
struct OrbButton: View {
    let title: String
    var tint: Color = Theme.mint
    var size: CGFloat = 116
    var busy = false
    var progress: Double? = nil      // vòng tiến độ quanh nút khi đang chạy
    var breathe = true
    let action: () -> Void
    @State private var hover = false
    @State private var spin = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if breathe && !busy { BreathingGlow(color: tint, size: size) }
                Circle().fill(Color.white.opacity(0.10)).frame(width: size + 22, height: size + 22)
                if busy, let progress {
                    Circle().trim(from: 0, to: max(0.02, progress))
                        .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .frame(width: size + 22, height: size + 22)
                        .rotationEffect(.degrees(-90))
                        .animation(Motion.spring, value: progress)
                } else if busy {
                    SpinningArc(diameter: size + 22, length: 0.25, lineWidth: 5, color: tint, period: 1)
                }
                Circle()
                    .fill(LinearGradient(colors: [tint, tint.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                    .frame(width: size, height: size)
                    .shadow(color: tint.opacity(hover ? 0.8 : 0.45), radius: hover ? 32 : 18)
                Group {
                    if busy {
                        Text(progress.map { "\(Int($0 * 100))%" } ?? "...")
                            .contentTransition(.numericText())
                    } else {
                        Text(title)
                    }
                }
                .font(.system(size: size * 0.19, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.82))
                .animation(Motion.spring, value: progress)
            }
            .scaleEffect(hover && !busy ? 1.04 : 1)
            .animation(Motion.snappy, value: hover)
        }
        .buttonStyle(PressableStyle(scale: 0.93))
        .onHover { hover = $0 }
        .disabled(busy)
    }
}

final class IconCache {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]
    func icon(for path: String?) -> NSImage {
        guard let path else { return NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil) ?? NSImage() }
        if let i = cache[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        cache[path] = i
        return i
    }
}

/// Một dòng app: icon, tên, thanh CPU, RAM, nút thoát.
struct AppRow: View {
    let app: AppUsage
    var compact = false
    var onQuit: (AppUsage) -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if app.bundlePath != nil {
                    Image(nsImage: IconCache.shared.icon(for: app.bundlePath)).resizable()
                } else {
                    Image(systemName: "gearshape.fill").resizable().scaledToFit().padding(3).foregroundStyle(Theme.text2)
                }
            }
            .frame(width: compact ? 20 : 26, height: compact ? 20 : 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).lineLimit(1)
                if !compact {
                    Text(app.bundlePath == nil ? "Chạy nền" : "\(app.pids.count) process")
                        .font(.caption2).foregroundStyle(Theme.text2)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Capsule().fill(Color.white.opacity(0.08)).frame(width: compact ? 34 : 40, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule().fill(levelColor(min(100, app.cpu * 0.8)))
                            .frame(width: (compact ? 34 : 40) * min(1, app.cpu / 100), height: 4)
                    }
                Text(String(format: "%.0f%%", app.cpu)).monospacedDigit()
                    .frame(width: 38, alignment: .trailing)
            }
            Text(fmtBytes(Int64(app.memBytes)))
                .monospacedDigit().foregroundStyle(Theme.text2)
                .frame(width: compact ? 62 : 78, alignment: .trailing)
            Button { onQuit(app) } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(hover ? Color(hex: 0xFF6B5B) : Color.white.opacity(0.35))
                    .scaleEffect(hover ? 1.15 : 1)
            }
            .buttonStyle(PressableStyle(scale: 0.8))
            .help("Thoát \(app.name)")
            .opacity(app.quittable ? 1 : 0)
            .disabled(!app.quittable)
            .frame(width: 18)
        }
        .font(compact ? .callout : .body)
        .padding(.vertical, compact ? 4 : 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(hover ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(Motion.snappy, value: hover)
    }
}

/// Hỏi lại trước khi thoát app.
struct QuitConfirm: ViewModifier {
    @Binding var target: AppUsage?
    @ObservedObject var monitor: SystemMonitor

    func body(content: Content) -> some View {
        content.alert(
            "Thoát \(target?.name ?? "")?",
            isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
            presenting: target
        ) { app in
            Button("Thoát") { monitor.quit(app) }
            Button("Buộc thoát", role: .destructive) { monitor.quit(app, force: true) }
            Button("Huỷ", role: .cancel) {}
        } message: { app in
            if app.name == "Google Chrome" {
                Text("Thoát Chrome sẽ đóng hết tab. Để tắt đúng tab nặng: trong Chrome bấm Shift+Esc, sắp xếp theo CPU, chọn tab rồi bấm End process.")
            } else {
                Text("Thoát: app sẽ hỏi lưu nếu có file chưa lưu.\nBuộc thoát: tắt ngay, mất phần chưa lưu.")
            }
        }
    }
}

extension View {
    func quitConfirm(_ target: Binding<AppUsage?>, monitor: SystemMonitor) -> some View {
        modifier(QuitConfirm(target: target, monitor: monitor))
    }
}
