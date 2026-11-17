import AppKit
import QuartzCore
import SwiftUI

// Bộ hiệu ứng dùng chung. Mọi hiệu ứng lặp đều tắt khi bật "Giảm chuyển động" trong macOS.

enum Motion {
    static let spring = Animation.spring(response: 0.45, dampingFraction: 0.82)
    static let snappy = Animation.spring(response: 0.3, dampingFraction: 0.78)
    static let value = Animation.easeOut(duration: 0.35)
}

/// Nút co lại khi bấm, bật lại khi thả.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.95
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

/// Phần tử trượt vào và hiện dần, lần lượt theo thứ tự.
struct StaggerIn: ViewModifier {
    let index: Int
    var dx: CGFloat = 0
    var dy: CGFloat = 14
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(x: shown || reduce ? 0 : dx, y: shown || reduce ? 0 : dy)
            .onAppear {
                guard !shown else { return }
                withAnimation(Motion.spring.delay(Double(min(index, 14)) * 0.035)) { shown = true }
            }
    }
}

extension View {
    func staggerIn(_ index: Int, dx: CGFloat = 0, dy: CGFloat = 14) -> some View {
        modifier(StaggerIn(index: index, dx: dx, dy: dy))
    }

    /// Phóng nhẹ và sáng lên khi rê chuột.
    func hoverLift(_ hover: Bool, scale: CGFloat = 1.012) -> some View {
        self.scaleEffect(hover ? scale : 1).animation(Motion.snappy, value: hover)
    }
}

/// Số đếm chạy từ giá trị cũ sang giá trị mới.
struct CountingBytes: View, Animatable {
    var value: Double
    var font: Font = .system(size: 50, weight: .bold, design: .rounded)
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    var body: some View {
        Text(fmtBytes(Int64(value))).font(font).monospacedDigit()
    }
}

/// Dấu tích tự vẽ.
struct CheckmarkShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + r.width * 0.18, y: r.minY + r.height * 0.52))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.42, y: r.minY + r.height * 0.75))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.84, y: r.minY + r.height * 0.27))
        return p
    }
}

/// Màn hình hoàn thành: vòng tròn bật ra, dấu tích tự vẽ, tia sáng toả ra.
struct DoneBadge: View {
    var size: CGFloat = 150
    @State private var pop = false
    @State private var draw = false
    @State private var burst = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        ZStack {
            ForEach(0..<12, id: \.self) { i in
                Image(systemName: i.isMultiple(of: 2) ? "sparkle" : "circle.fill")
                    .font(.system(size: i.isMultiple(of: 2) ? 14 : 6))
                    .foregroundStyle(Theme.mint)
                    .offset(y: burst ? -size * 0.95 : -size * 0.4)
                    .rotationEffect(.degrees(Double(i) * 30))
                    .opacity(burst ? 0 : (pop ? 1 : 0))
            }
            Circle().fill(Theme.mint)
                .frame(width: size, height: size)
                .shadow(color: Theme.mint.opacity(0.6), radius: 30)
                .scaleEffect(pop ? 1 : 0.3)
            CheckmarkShape()
                .trim(from: 0, to: draw ? 1 : 0)
                .stroke(Color.black.opacity(0.8), style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.5, height: size * 0.5)
        }
        .onAppear {
            if reduce { pop = true; draw = true; burst = true; return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { pop = true }
            withAnimation(.easeOut(duration: 0.45).delay(0.25)) { draw = true }
            withAnimation(.easeOut(duration: 0.9).delay(0.2)) { burst = true }
        }
    }
}

// MARK: - Hiệu ứng lặp chạy bằng Core Animation
// Hiệu ứng lặp do tiến trình vẽ của macOS chạy, app không phải vẽ lại từng khung hình nên gần như không tốn CPU.

/// NSView có layer, gọi lại khi đổi kích thước để đặt lại khung các layer con.
final class LayerView: NSView {
    var onLayout: ((CALayer, CGRect) -> Void)?
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer = CALayer() }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        onLayout?(layer!, bounds)
        CATransaction.commit()
    }
}

private func loop(_ anims: [CAAnimation], duration: Double, reverse: Bool, delay: Double = 0) -> CAAnimationGroup {
    let g = CAAnimationGroup()
    g.animations = anims
    g.duration = duration
    g.autoreverses = reverse
    g.repeatCount = .infinity
    g.beginTime = CACurrentMediaTime() + delay
    g.fillMode = .backwards
    g.timingFunction = CAMediaTimingFunction(name: reverse ? .easeInEaseOut : .easeOut)
    g.isRemovedOnCompletion = false
    return g
}

private func basic(_ key: String, _ from: Any, _ to: Any) -> CABasicAnimation {
    let a = CABasicAnimation(keyPath: key); a.fromValue = from; a.toValue = to; return a
}

/// Quầng sáng "thở" chậm phía sau nút chính.
struct BreathingGlow: NSViewRepresentable {
    var color: Color
    var size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduce

    func makeNSView(context: Context) -> LayerView {
        let v = LayerView()
        let g = CAGradientLayer()
        g.type = .radial
        let c = NSColor(color)
        g.colors = [c.withAlphaComponent(0.45).cgColor, c.withAlphaComponent(0.45).cgColor, c.withAlphaComponent(0).cgColor]
        g.locations = [0, 0.33, 1]
        g.startPoint = CGPoint(x: 0.5, y: 0.5)
        g.endPoint = CGPoint(x: 1, y: 1)
        v.layer!.addSublayer(g)
        if !reduce {
            g.add(loop([basic("transform.scale", 0.92, 1.08), basic("opacity", 0.6, 1.0)], duration: 2.2, reverse: true), forKey: "breathe")
        }
        v.onLayout = { _, b in g.frame = b }
        return v
    }
    func updateNSView(_ v: LayerView, context: Context) {}
    func sizeThatFits(_ p: ProposedViewSize, nsView: LayerView, context: Context) -> CGSize? {
        CGSize(width: size * 1.8, height: size * 1.8)
    }
}

/// Các vòng sóng toả ra liên tục (dùng khi đang quét).
struct PulseRings: NSViewRepresentable {
    var size: CGFloat
    var color: Color = Theme.mint
    @Environment(\.accessibilityReduceMotion) private var reduce

    func makeNSView(context: Context) -> LayerView {
        let v = LayerView()
        var rings: [CAShapeLayer] = []
        for i in 0..<3 {
            let r = CAShapeLayer()
            r.fillColor = nil
            r.strokeColor = NSColor(color).withAlphaComponent(0.5).cgColor
            r.lineWidth = 1.5
            r.opacity = reduce ? 0.5 : 0
            v.layer!.addSublayer(r)
            rings.append(r)
            if !reduce {
                r.add(loop([basic("transform.scale", 1.0, 1.6), basic("opacity", 0.8, 0.0)], duration: 2.4, reverse: false, delay: Double(i) * 0.8), forKey: "pulse")
            }
        }
        v.onLayout = { _, b in
            for r in rings {
                r.frame = b
                r.path = CGPath(ellipseIn: CGRect(x: (b.width - size) / 2, y: (b.height - size) / 2, width: size, height: size), transform: nil)
            }
        }
        return v
    }
    func updateNSView(_ v: LayerView, context: Context) {}
    func sizeThatFits(_ p: ProposedViewSize, nsView: LayerView, context: Context) -> CGSize? {
        CGSize(width: size * 1.7, height: size * 1.7)
    }
}

/// Vệt cung tròn xoay liên tục.
struct SpinningArc: NSViewRepresentable {
    var diameter: CGFloat
    var length: CGFloat = 0.12       // phần của vòng tròn
    var lineWidth: CGFloat = 4
    var color: Color = .white
    var period: Double = 1.6
    @Environment(\.accessibilityReduceMotion) private var reduce

    func makeNSView(context: Context) -> LayerView {
        let v = LayerView()
        let arc = CAShapeLayer()
        arc.fillColor = nil
        arc.strokeColor = NSColor(color).cgColor
        arc.lineWidth = lineWidth
        arc.lineCap = .round
        arc.strokeEnd = length
        v.layer!.addSublayer(arc)
        if !reduce {
            let rot = basic("transform.rotation.z", 0.0, -2 * Double.pi)
            rot.duration = period
            rot.repeatCount = .infinity
            rot.isRemovedOnCompletion = false
            arc.add(rot, forKey: "spin")
        }
        v.onLayout = { _, b in
            arc.frame = b
            let r = CGRect(x: (b.width - diameter) / 2, y: (b.height - diameter) / 2, width: diameter, height: diameter)
            arc.path = CGPath(ellipseIn: r, transform: nil)
        }
        return v
    }
    func updateNSView(_ v: LayerView, context: Context) {}
    func sizeThatFits(_ p: ProposedViewSize, nsView: LayerView, context: Context) -> CGSize? {
        CGSize(width: diameter + lineWidth * 2, height: diameter + lineWidth * 2)
    }
}
