import SwiftUI

/// Quét nhanh: chạy nhiều bước quét cùng lúc, tóm tắt, rồi dọn rác bằng một nút.
@MainActor
final class SmartScanModel: ObservableObject {
    static let shared = SmartScanModel()
    enum Phase { case idle, scanning, ready, running, finished }
    @Published var phase: Phase = .idle
    @Published var step = ""
    @Published var stepIndex = 0
    let steps = [String(localized: "Rác và cache"), String(localized: "App có bản mới"), String(localized: "Mục chạy nền"), String(localized: "File lớn")]

    private func waitWhile(_ busy: @escaping () -> Bool) async {
        while busy() { try? await Task.sleep(nanoseconds: 300_000_000) }
    }

    func scan() {
        guard phase != .scanning, phase != .running else { return }
        phase = .scanning
        Task {
            stepIndex = 0; step = steps[0]
            await Cleaner.shared.scanAsync()
            stepIndex = 1; step = steps[1]
            UpdaterModel.shared.load()
            await waitWhile { UpdaterModel.shared.loading }
            stepIndex = 2; step = steps[2]
            StartupModel.shared.load()
            await waitWhile { StartupModel.shared.loading }
            stepIndex = 3; step = steps[3]
            await LargeFilesModel.shared.scanAsync()
            phase = .ready
        }
    }

    func run(monitor: SystemMonitor) {
        phase = .running
        Task {
            await Cleaner.shared.cleanAsync(monitor: monitor)
            phase = .finished
        }
    }
}

struct SmartScanView: View {
    @ObservedObject var m = SmartScanModel.shared
    @ObservedObject var cleaner = Cleaner.shared
    @ObservedObject var updater = UpdaterModel.shared
    @ObservedObject var startup = StartupModel.shared
    @ObservedObject var large = LargeFilesModel.shared
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var nav: Nav
    @State private var confirm = false

    var body: some View {
        switch m.phase {
        case .idle:
            EmptyHint(icon: "wand.and.stars", title: String(localized: "Kiểm tra toàn bộ máy bằng một lần quét"),
                      detail: String(localized: "Tìm rác và cache, app có bản mới, mục chạy nền đáng ngờ, file lớn. Chưa xoá gì cho tới khi bạn bấm Dọn."),
                      action: (String(localized: "Quét"), { m.scan() }))
        case .scanning:
            VStack(spacing: 22) {
                ScanningView(name: m.step, progress: Double(m.stepIndex) / Double(m.steps.count))
                HStack(spacing: 18) {
                    ForEach(Array(m.steps.enumerated()), id: \.offset) { i, s in
                        HStack(spacing: 6) {
                            Image(systemName: i < m.stepIndex ? "checkmark.circle.fill" : (i == m.stepIndex ? "circle.dotted" : "circle"))
                                .contentTransition(.symbolEffect(.replace))
                                .symbolEffect(.bounce, value: i < m.stepIndex)
                            Text(s)
                        }
                        .foregroundStyle(i <= m.stepIndex ? Theme.mint : Theme.text2)
                        .font(.callout)
                        .animation(Motion.spring, value: m.stepIndex)
                    }
                }
                .padding(.bottom, 60)
            }
        case .ready, .running, .finished:
            results
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: m.phase == .finished ? String(localized: "Đã dọn xong") : String(localized: "Kết quả quét"),
                       subtitle: m.phase == .finished
                           ? String(localized: "Đã lấy lại \(fmtBytes(cleaner.lastFreed ?? 0)). Ổ đang trống \(fmtBytes(monitor.diskFree)).")
                           : String(localized: "Bấm Dọn để xoá rác và cache đã chọn. Các mục khác cần bạn tự xem."))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                tile("sparkles", String(localized: "Rác và cache"), fmtBytes(cleaner.selectedSize), String(localized: "\(cleaner.items.filter(\.selected).count) mục"), .clean).staggerIn(0)
                tile("arrow.down.circle", String(localized: "App có bản mới"), "\(updater.items.count)", String(localized: "qua Homebrew và App Store"), .update).staggerIn(1)
                tile("exclamationmark.shield", String(localized: "Mục chạy nền đáng ngờ"), "\(startup.suspiciousCount)",
                     String(localized: "chưa ký hoặc mất file, trên \(startup.agents.count) mục"), .startup,
                     warn: startup.suspiciousCount > 0).staggerIn(2)
                tile("doc.badge.ellipsis", String(localized: "File trên 100 MB"), "\(large.files.count)",
                     fmtBytes(large.files.reduce(0) { $0 + $1.size }), .large).staggerIn(3)
                tile("memorychip", "Swap", fmtGB(monitor.swapUsed),
                     monitor.swapHigh ? String(localized: "RAM không đủ, nên tắt bớt app") : String(localized: "Bình thường"), .memory, warn: monitor.swapHigh).staggerIn(4)
                tile("power", String(localized: "Lần restart gần nhất"), String(localized: "\(monitor.uptimeDays) ngày"),
                     monitor.uptimeDays >= 5 ? String(localized: "Nên restart để xoá swap") : String(localized: "Bình thường"), .overview, warn: monitor.uptimeDays >= 5).staggerIn(5)
            }
            Spacer()
            HStack(spacing: 30) {
                Spacer()
                Button { m.scan() } label: { Label("Quét lại", systemImage: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(Theme.text2).disabled(m.phase == .running)
                OrbButton(title: m.phase == .finished ? String(localized: "Xong") : String(localized: "Dọn"), size: 100, busy: m.phase == .running) {
                    if m.phase == .finished { m.phase = .idle; cleaner.lastFreed = nil } else { confirm = true }
                }
                .disabled(m.phase != .finished && cleaner.selectedSize == 0)
                Spacer()
            }
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 32)
        .alert("Dọn \(fmtBytes(cleaner.selectedSize)) rác và cache?", isPresented: $confirm) {
            Button("Dọn", role: .destructive) { m.run(monitor: monitor) }
            Button("Huỷ", role: .cancel) {}
        } message: { Text(cleaner.items.filter(\.selected).map(\.name).joined(separator: "\n")) }
    }

    private func tile(_ icon: String, _ title: String, _ value: String, _ detail: String, _ page: Page, warn: Bool = false) -> some View {
        Tile(icon: icon, title: title, value: value, detail: detail, warn: warn) { withAnimation { nav.page = page } }
    }
}

struct Tile: View {
    let icon: String, title: String, value: String, detail: String
    var warn = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 20))
                    .foregroundStyle(warn ? Color(hex: 0xF2B544) : Theme.mint)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Theme.text2)
                    Text(value).font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                    Text(detail).font(.caption).foregroundStyle(warn ? Color(hex: 0xF2B544) : Theme.text2).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Theme.text2)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.glass))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(hover ? Theme.mint.opacity(0.35) : Theme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.97))
        .hoverLift(hover, scale: 1.015)
        .onHover { hover = $0 }
    }
}
