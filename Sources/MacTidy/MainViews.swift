import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case smart, overview, clean, privacy, maintenance, startup, memory, cpu, uninstall, update, space, large, dupes, menubar
    var id: String { rawValue }
    var title: String {
        switch self {
        case .smart: String(localized: "Quét nhanh")
        case .overview: String(localized: "Tổng quan")
        case .clean: String(localized: "Dọn rác")
        case .privacy: String(localized: "Quyền riêng tư")
        case .maintenance: String(localized: "Bảo trì")
        case .startup: String(localized: "Mục khởi động")
        case .memory: "RAM"
        case .cpu: String(localized: "CPU và nhiệt")
        case .uninstall: String(localized: "Gỡ cài đặt")
        case .update: String(localized: "Cập nhật")
        case .space: String(localized: "Bản đồ ổ đĩa")
        case .large: String(localized: "File lớn và cũ")
        case .dupes: String(localized: "File trùng")
        case .menubar: String(localized: "Gom icon thanh menu")
        }
    }
    var icon: String {
        switch self {
        case .smart: "wand.and.stars"
        case .overview: "gauge.with.dots.needle.67percent"
        case .clean: "sparkles"
        case .privacy: "hand.raised"
        case .maintenance: "wrench.and.screwdriver"
        case .startup: "power"
        case .memory: "memorychip"
        case .cpu: "cpu"
        case .uninstall: "xmark.app"
        case .update: "arrow.down.circle"
        case .space: "chart.pie"
        case .large: "doc.badge.ellipsis"
        case .dupes: "doc.on.doc"
        case .menubar: "menubar.rectangle"
        }
    }
    static let groups: [(String?, [Page])] = [
        (nil, [.smart, .overview]),
        (String(localized: "Dọn dẹp"), [.clean, .privacy]),
        (String(localized: "Tốc độ"), [.maintenance, .startup, .memory, .cpu]),
        (String(localized: "Ứng dụng"), [.uninstall, .update]),
        ("File", [.space, .large, .dupes]),
        (String(localized: "Tiện ích"), [.menubar]),
    ]
}

@MainActor
final class Nav: ObservableObject {
    static let shared = Nav()
    @Published var page: Page? = .smart
}

// MARK: - Khung cửa sổ

struct MainView: View {
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var monitor: SystemMonitor

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 214)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            ZStack {
                Group {
                switch nav.page ?? .smart {
                case .smart: SmartScanView()
                case .overview: OverviewView()
                case .clean: CleanView()
                case .privacy: PrivacyView()
                case .maintenance: MaintenanceView()
                case .startup: StartupView()
                case .memory: MemoryView()
                case .cpu: CPUView()
                case .uninstall: UninstallerView()
                case .update: UpdaterView()
                case .space: SpaceLensView()
                case .large: LargeFilesView()
                case .dupes: DupesView()
                case .menubar: MenuBarItemsView()
                }
                }
                .id(nav.page)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 16)).combined(with: .scale(scale: 0.985)),
                                        removal: .opacity))
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.88), value: nav.page)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
        .background(ThermalBackground(state: monitor.thermal))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .frame(minWidth: 960, minHeight: 660)
        .ignoresSafeArea()
    }
}

struct Sidebar: View {
    @Namespace private var ns
    @State private var hovered: Page?
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var cleaner: Cleaner

    var body: some View {
        let t = Thermal(state: monitor.thermal)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.mint)
                Text("MacTidy").font(.system(size: 17, weight: .semibold, design: .rounded))
                Spacer()
                Menu {
                    LanguagePicker().pickerStyle(.inline)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "globe")
                        Text(verbatim: AppLanguage.current.uppercased())
                    }
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text2)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(Text(verbatim: "Ngôn ngữ / Language"))
            }
            .padding(.horizontal, 14)
            .padding(.top, 42)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(Page.groups.enumerated()), id: \.offset) { _, g in
                        if let title = g.0 {
                            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.text2)
                                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 2)
                        }
                        ForEach(g.1) { p in item(p) }
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.never)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: t.icon).foregroundStyle(t.color)
                    Text(t.title).font(.callout.weight(.medium))
                }
                StatBar(title: "CPU", value: "\(Int(monitor.cpu))%", fraction: monitor.cpu / 100, compact: true)
                StatBar(title: "RAM", value: fmtGB(monitor.memUsed), fraction: monitor.memPercent / 100, compact: true)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.18)))
            .padding(10)
        }
        .background(Color.black.opacity(0.16))
    }

    private func item(_ p: Page) -> some View {
        let selected = (nav.page ?? .smart) == p
        return Button { withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { nav.page = p } } label: {
            HStack(spacing: 10) {
                Image(systemName: p.icon).frame(width: 20)
                    .foregroundStyle(selected ? Theme.mint : Theme.text2)
                    .symbolEffect(.bounce, value: selected)
                Text(p.title)
                Spacer()
                if p == .clean, cleaner.selectedSize > 0, !cleaner.scanning {
                    Text(fmtBytes(cleaner.selectedSize)).font(.caption).foregroundStyle(Theme.text2)
                }
            }
            .font(.system(size: 13.5, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.13))
                        .matchedGeometryEffect(id: "sel", in: ns)
                } else if hovered == p {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.05))
                }
            }
            .contentShape(Rectangle())
            .onHover { hovered = $0 ? p : (hovered == p ? nil : hovered) }
            .animation(Motion.snappy, value: hovered)
        }
        .buttonStyle(PressableStyle(scale: 0.97))
    }
}

/// Tiêu đề trang.
struct PageHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 30, weight: .bold, design: .rounded))
            Text(subtitle).foregroundStyle(Theme.text2)
        }
        .padding(.top, 40)
    }
}

// MARK: - Tổng quan

struct OverviewView: View {
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var nav: Nav
    @State private var quitTarget: AppUsage?

    var body: some View {
        let t = Thermal(state: monitor.thermal)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center, spacing: 36) {
                    Dial(value: monitor.cpu, label: "CPU", size: 230, line: 18).staggerIn(0, dy: 0)
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(t.title, systemImage: t.icon)
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            Text(t.detail).foregroundStyle(Theme.text2)
                            if let c = monitor.temps.cpu {
                                Text("CPU \(Int(c.rounded()))°C, GPU \(monitor.temps.gpu.map { "\(Int($0.rounded()))°C" } ?? "—")")
                                    .font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                            }
                        }
                        StatBar(title: "RAM", value: "\(fmtGB(monitor.memUsed)) / \(fmtGB(monitor.memTotal))",
                                fraction: monitor.memPercent / 100)
                        StatBar(title: "Swap", value: fmtGB(monitor.swapUsed),
                                fraction: Double(monitor.swapUsed) / Double(max(1, monitor.memTotal)))
                        StatBar(title: String(localized: "Ổ đĩa còn trống"), value: fmtBytes(monitor.diskFree),
                                fraction: monitor.diskUsedPercent / 100)
                    }
                    .frame(maxWidth: 420)
                }
                .padding(.top, 44)

                cpuChart

                HStack(alignment: .top, spacing: 16) {
                    Glass {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Đang tốn CPU nhất").font(.headline)
                                Spacer()
                                Button("Xem tất cả") { nav.page = .cpu }.buttonStyle(.plain).foregroundStyle(Theme.mint)
                            }
                            .padding(.horizontal, 8).padding(.bottom, 4)
                            let top = Array(monitor.byCPU.prefix(6))
                            ForEach(Array(top.enumerated()), id: \.element.id) { i, a in
                                AppRow(app: a) { quitTarget = $0 }.staggerIn(i)
                            }
                            .animation(Motion.value, value: top.map(\.id))
                        }
                    }
                    tips.frame(width: 280)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.never)
        .quitConfirm($quitTarget, monitor: monitor)
    }

    private var cpuChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CPU trong 4 phút gần nhất").font(.caption).foregroundStyle(Theme.text2)
            Sparkline(values: monitor.cpuHistory, capacity: 90)
                .frame(height: 90)
        }
        .padding(.top, 4)
    }

    @ViewBuilder private var tips: some View {
        let hot = monitor.byCPU.first { $0.cpu >= 50 && $0.quittable }
        let list: [(String, String, (() -> Void)?)] = [
            hot.map { a in ("flame.fill", String(localized: "\(a.name) đang dùng \(Int(a.cpu))% CPU."), { quitTarget = a }) },
            monitor.swapHigh ? ("arrow.triangle.2.circlepath", String(localized: "Swap \(fmtGB(monitor.swapUsed)): RAM không đủ. Tắt bớt app tốn RAM."), { nav.page = .memory }) : nil,
            monitor.uptimeDays >= 5 ? ("power", String(localized: "Máy chạy \(monitor.uptimeDays) ngày chưa restart. Restart để xoá swap."), nil) : nil,
            monitor.diskTotal > 0 && monitor.diskFree < 20_000_000_000 ? ("externaldrive.badge.exclamationmark", String(localized: "Ổ chỉ còn \(fmtBytes(monitor.diskFree))."), { nav.page = .clean }) : nil,
        ].compactMap { $0 }
        Glass {
            VStack(alignment: .leading, spacing: 14) {
                Text("Nên làm").font(.headline)
                if list.isEmpty {
                    Label("Máy đang ổn, không cần làm gì.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.mint)
                }
                ForEach(Array(list.enumerated()), id: \.offset) { _, tip in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: tip.0).foregroundStyle(Color(hex: 0xF2B544)).frame(width: 18)
                            Text(tip.1).fixedSize(horizontal: false, vertical: true)
                        }
                        if let action = tip.2 {
                            Button("Xử lý", action: action)
                                .buttonStyle(.plain)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(Theme.mint)
                                .padding(.leading, 28)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Dọn rác: chưa quét → đang quét → kết quả → đang dọn → xong

struct CleanView: View {
    @EnvironmentObject var cleaner: Cleaner
    @EnvironmentObject var monitor: SystemMonitor
    @State private var confirm = false

    var body: some View {
        Group {
            if let freed = cleaner.lastFreed, !cleaner.cleaning {
                done(freed)
            } else if cleaner.scanning && !cleaner.cleaning {
                ScanningView(name: cleaner.scanningName, progress: cleaner.progress)
            } else if cleaner.scannedOnce {
                results
            } else {
                idle
            }
        }
        .alert("Dọn \(fmtBytes(cleaner.selectedSize))?", isPresented: $confirm) {
            Button("Dọn", role: .destructive) { cleaner.clean(monitor: monitor) }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text(cleaner.items.filter(\.selected).map(\.name).joined(separator: "\n"))
        }
    }

    private var idle: some View {
        VStack(spacing: 26) {
            Spacer()
            ZStack {
                BreathingGlow(color: Theme.mint, size: 180)
                Circle().fill(Theme.mint.opacity(0.08)).frame(width: 220, height: 220)
                Circle().stroke(Theme.mint.opacity(0.25), lineWidth: 1).frame(width: 220, height: 220)
                Image(systemName: "sparkles").font(.system(size: 76, weight: .light)).foregroundStyle(Theme.mint)
                    .symbolEffect(.bounce, options: .nonRepeating, value: cleaner.scannedOnce)
            }
            .staggerIn(0)
            VStack(spacing: 8) {
                Text("Dọn cache của tool dev").font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Docker, Go, uv, npm, Homebrew, Xcode. Xoá xong tool tự tạo lại khi cần, không mất code.")
                    .foregroundStyle(Theme.text2).multilineTextAlignment(.center).frame(maxWidth: 420)
                    .fixedSize(horizontal: false, vertical: true)
            }
            OrbButton(title: String(localized: "Quét")) { cleaner.scan() }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var results: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                Spacer().frame(height: 30)
                CountingBytes(value: Double(cleaner.selectedSize))
                    .minimumScaleFactor(0.6).lineLimit(1)
                    .animation(.easeOut(duration: 0.6), value: cleaner.selectedSize)
                    .staggerIn(0)
                Text(cleaner.cleaning ? "Đang dọn..." : "sẽ được dọn từ \(cleaner.items.filter(\.selected).count) mục đã chọn")
                    .foregroundStyle(Theme.text2)
                Text("Ổ đang trống \(fmtBytes(monitor.diskFree)).").foregroundStyle(Theme.text2)
                Spacer()
                HStack {
                    Spacer()
                    OrbButton(title: String(localized: "Dọn"), busy: cleaner.cleaning, progress: cleaner.cleaning ? cleaner.cleanProgress : nil) { confirm = true }
                        .disabled(cleaner.selectedSize == 0)
                        .opacity(cleaner.selectedSize == 0 ? 0.4 : 1)
                    Spacer()
                }
                Button { cleaner.scan() } label: { Label("Quét lại", systemImage: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(Theme.text2)
                    .frame(maxWidth: .infinity)
                    .disabled(cleaner.cleaning)
                Spacer().frame(height: 20)
            }
            .frame(width: 236)

            ScrollView {
                VStack(spacing: 8) {
                    if cleaner.items.isEmpty {
                        Glass { Label("Không còn cache nào trên 50 MB.", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.mint) }
                    }
                    ForEach(Array($cleaner.items.enumerated()), id: \.element.id) { i, $item in
                        CleanRow(item: $item, disabled: cleaner.cleaning).staggerIn(i, dx: 40, dy: 0)
                    }
                }
                .padding(.vertical, 40)
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 32)
    }

    private func done(_ freed: Int64) -> some View {
        VStack(spacing: 22) {
            Spacer()
            DoneBadge()
            DoneTitle(freed: freed)
            Text("Ổ đang trống \(fmtBytes(monitor.diskFree)).").foregroundStyle(Theme.text2)
            let failed = cleaner.lastFailed
            if !failed.isEmpty {
                Text("Chưa dọn được: \(failed.joined(separator: ", ")). Có app khác đang dùng, thử lại sau khi tắt app đó.")
                    .foregroundStyle(Color(hex: 0xF2B544)).multilineTextAlignment(.center).frame(maxWidth: 460)
            }
            Button("Xong") { cleaner.lastFreed = nil }
                .buttonStyle(.borderedProminent).tint(Theme.mint).foregroundStyle(.black).controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct CleanRow: View {
    @Binding var item: CleanItem
    let disabled: Bool
    @State private var hover = false
    @ObservedObject private var ai = AIAdvisor.shared

    private var aiPaths: [String] { item.trashPaths.isEmpty ? item.paths : item.trashPaths }
    private var aiAction: String {
        item.trashPaths.isEmpty ? "chạy lệnh: " + String(item.cleanCmd.prefix(300)) : "chuyển các file trên vào Thùng rác"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 14) {
            Image(systemName: item.icon)
                .font(.system(size: 17))
                .foregroundStyle(item.warn ? Color(hex: 0xFF6B5B) : Theme.mint)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.body.weight(.medium)).lineLimit(1)
                Text(item.detail).font(.caption).foregroundStyle(item.warn ? Color(hex: 0xFF8A7A) : Theme.text2)
                    .lineLimit(1).truncationMode(.middle)
            }
            .layoutPriority(1)
            Spacer()
            switch item.state {
            case .running: ProgressView().controlSize(.small)
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.mint)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(hex: 0xF2B544))
            case .idle: EmptyView()
            }
            if !aiPaths.isEmpty {
                AskAIButton(key: "clean-" + item.id, title: item.name, paths: aiPaths, action: aiAction, size: item.size)
                    .opacity(hover || ai.states["clean-" + item.id] != nil ? 1 : 0.55)
            }
            Text(fmtBytes(item.size)).font(.system(.body, design: .rounded).weight(.semibold)).monospacedDigit()
                .frame(width: 86, alignment: .trailing)
            Toggle("", isOn: $item.selected).labelsHidden().toggleStyle(.switch).tint(Theme.mint).disabled(disabled)
        }
        AIVerdictView(key: "clean-" + item.id)
        }
        .animation(Motion.spring, value: ai.states["clean-" + item.id])
        .onChange(of: ai.states["clean-" + item.id]) { _, s in
            // AI báo đang được dùng: tự bỏ chọn để không xoá nhầm
            if case .done(let v, _) = s, v.verdict == "in_use" { item.selected = false }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(item.selected ? (hover ? 0.11 : 0.08) : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(item.state == .running ? Theme.mint.opacity(0.6) : Theme.hairline))
        .opacity(item.selected ? 1 : 0.6)
        .hoverLift(hover)
        .onHover { hover = $0 }
        .animation(Motion.snappy, value: item.selected)
        .animation(Motion.spring, value: item.state)
    }
}

/// Màn hình đang quét: sóng toả ra, vòng tiến độ đầy dần, vệt sáng xoay.
struct ScanningView: View {
    let name: String
    let progress: Double
    @State private var spin = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            ZStack {
                PulseRings(size: 220)
                BreathingGlow(color: Theme.mint, size: 170)
                Circle().stroke(Color.white.opacity(0.08), lineWidth: 10).frame(width: 220, height: 220)
                Circle().trim(from: 0, to: max(0.01, progress))
                    .stroke(Theme.mint.opacity(0.9), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .frame(width: 220, height: 220)
                    .rotationEffect(.degrees(-90))
                    .animation(Motion.spring, value: progress)
                SpinningArc(diameter: 246, color: .white.opacity(0.85))
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 44, weight: .semibold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText(value: progress))
                    .animation(Motion.spring, value: progress)
            }
            .frame(width: 300, height: 300)
            VStack(spacing: 6) {
                Text("Đang quét").font(.system(size: 26, weight: .bold, design: .rounded))
                Text(name.isEmpty ? " " : name)
                    .foregroundStyle(Theme.text2)
                    .contentTransition(.opacity)
                    .id(name)
                    .transition(.asymmetric(insertion: .offset(y: 8).combined(with: .opacity), removal: .offset(y: -8).combined(with: .opacity)))
                    .animation(Motion.spring, value: name)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onAppear { spin = true }
    }
}

// MARK: - RAM

struct MemoryView: View {
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var docker: DockerModel
    @State private var quitTarget: AppUsage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "RAM", subtitle: String(localized: "macOS không có cách \"dọn RAM\" thật sự. Tắt app tốn RAM, hoặc restart máy để xoá swap."))
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fmtGB(monitor.memUsed)).font(.system(size: 48, weight: .bold, design: .rounded)).monospacedDigit()
                        Text("đang dùng trên \(fmtGB(monitor.memTotal))").foregroundStyle(Theme.text2)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        StatBar(title: "RAM", value: "\(Int(monitor.memPercent))%", fraction: monitor.memPercent / 100)
                        StatBar(title: String(localized: "Swap (dữ liệu bị đẩy ra ổ đĩa vì thiếu RAM)"), value: fmtGB(monitor.swapUsed),
                                fraction: Double(monitor.swapUsed) / Double(max(1, monitor.memTotal)))
                    }
                }
                Glass(padding: 12) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        Text("App tốn RAM").font(.headline).padding(8)
                        ForEach(Array(monitor.byMem.prefix(14).enumerated()), id: \.element.id) { i, a in
                            AppRow(app: a) { quitTarget = $0 }.staggerIn(i)
                        }
                    }

                }
                Glass(padding: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Docker container").font(.headline)
                            Spacer()
                            if docker.loading { ProgressView().controlSize(.small) }
                            Button { docker.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain)
                        }
                        .padding(8)
                        if !docker.available {
                            Text("Docker hoặc OrbStack chưa chạy.").foregroundStyle(Theme.text2).padding(8)
                        } else if docker.containers.isEmpty && !docker.loading {
                            Text("Không có container nào đang chạy.").foregroundStyle(Theme.text2).padding(8)
                        }
                        ForEach(docker.containers) { c in
                            HStack(spacing: 10) {
                                Image(systemName: "shippingbox.fill").foregroundStyle(Color(hex: 0x6CB8FF)).frame(width: 26)
                                Text(c.id)
                                Spacer()
                                Text(c.cpuText).monospacedDigit().foregroundStyle(Theme.text2).frame(width: 60, alignment: .trailing)
                                Text(c.memText).monospacedDigit().frame(width: 90, alignment: .trailing)
                                Button("Dừng") { docker.stop(c.id) }
                                    .buttonStyle(.plain).foregroundStyle(Theme.mint).frame(width: 44)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 6)
                        }
                    }
                }
            }
            .padding(.horizontal, 32).padding(.bottom, 28)
        }
        .scrollIndicators(.never)
        .onAppear { docker.refresh() }
        .quitConfirm($quitTarget, monitor: monitor)
    }
}

// MARK: - CPU

struct CPUView: View {
    @EnvironmentObject var monitor: SystemMonitor
    @State private var quitTarget: AppUsage?
    @State private var onlyApps = false

    var body: some View {
        let t = Thermal(state: monitor.thermal)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: String(localized: "CPU và nhiệt"), subtitle: String(localized: "100% = dùng hết 1 core. Máy có \(ProcessInfo.processInfo.activeProcessorCount) core."))
                HStack(spacing: 30) {
                    Dial(value: monitor.cpu, label: String(localized: "Tổng CPU"), size: 170, line: 14)
                    VStack(alignment: .leading, spacing: 8) {
                        Label(t.title, systemImage: t.icon).font(.title2.bold()).foregroundStyle(t.color)
                        Text(t.detail)
                        HStack(spacing: 22) {
                            tempStat("CPU", monitor.temps.cpu)
                            tempStat("GPU", monitor.temps.gpu)
                            tempStat(String(localized: "Nhân nóng nhất"), monitor.temps.cpuMax)
                        }
                        Text("Đọc từ cảm biến SMC. Mức Mát, Ấm, Nóng, Rất nóng là mức macOS tự đánh giá; từ mức Nóng macOS bắt đầu giảm tốc CPU.")
                            .font(.callout).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Glass(padding: 12) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Tất cả process, gộp theo app").font(.headline)
                            Spacer()
                            Toggle("Chỉ hiện app", isOn: $onlyApps).toggleStyle(.switch).controlSize(.small).tint(Theme.mint)
                        }
                        .padding(8)
                        let list = Array(monitor.byCPU.filter { !onlyApps || $0.bundlePath != nil }.prefix(40))
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, a in
                            AppRow(app: a) { quitTarget = $0 }.staggerIn(i)
                        }

                    }
                }
            }
            .padding(.horizontal, 32).padding(.bottom, 28)
        }
        .scrollIndicators(.never)
        .quitConfirm($quitTarget, monitor: monitor)
    }

    private func tempStat(_ label: String, _ v: Double?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.caption).foregroundStyle(Theme.text2)
            Text(v.map { "\(Int($0.rounded()))°C" } ?? "—")
                .font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(v.map { $0 >= 95 ? Color(hex: 0xFF6B5B) : ($0 >= 80 ? Color(hex: 0xF2B544) : Color.white) } ?? .white)
        }
    }
}

/// Tiêu đề màn hình dọn xong: số GB đếm từ 0 lên.
struct DoneTitle: View {
    let freed: Int64
    @State private var shown: Double = 0
    var body: some View {
        HStack(spacing: 10) {
            Text("Đã lấy lại").font(.system(size: 34, weight: .bold, design: .rounded))
            CountingBytes(value: shown, font: .system(size: 34, weight: .bold, design: .rounded))
        }
        .onAppear { withAnimation(.easeOut(duration: 1.2).delay(0.3)) { shown = Double(freed) } }
    }
}

/// Biểu đồ CPU vẽ bằng Path: nhẹ hơn nhiều so với framework Charts khi cập nhật mỗi 3 giây.
struct Sparkline: View {
    let values: [Double]      // 0...100
    let capacity: Int

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let step = w / CGFloat(max(1, capacity - 1))
            let x0 = w - CGFloat(max(0, values.count - 1)) * step
            let pts = values.enumerated().map { CGPoint(x: x0 + CGFloat($0.offset) * step, y: h - h * CGFloat(min(100, $0.element)) / 100) }
            ZStack {
                ForEach([0.0, 0.5, 1.0], id: \.self) { f in
                    Path { p in p.move(to: CGPoint(x: 0, y: h * f)); p.addLine(to: CGPoint(x: w, y: h * f)) }
                        .stroke(Theme.hairline, lineWidth: 1)
                }
                if pts.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: h))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: pts.last!.x, y: h))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [Theme.mint.opacity(0.3), Theme.mint.opacity(0)], startPoint: .top, endPoint: .bottom))
                    Path { p in p.addLines(pts) }
                        .stroke(Theme.mint, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                }
            }
        }
        .drawingGroup()
    }
}
