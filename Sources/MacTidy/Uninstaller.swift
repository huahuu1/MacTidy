import AppKit
import SwiftUI

struct AppInfo: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    let bundleID: String
    let version: String
    var size: Int64? = nil
    var lastUsed: Date? = nil
    var unused: Bool { (lastUsed.map { Date().timeIntervalSince($0) > 90 * 86_400 }) ?? true }
}

struct Leftover: Identifiable {
    var id: String { path }
    let path: String
    let size: Int64
    var selected = true
}

@MainActor
final class AppsModel: ObservableObject {
    static let shared = AppsModel()
    @Published var apps: [AppInfo] = []
    @Published var loading = false
    @Published var loaded = false
    @Published var selected: AppInfo?
    @Published var leftovers: [Leftover] = []
    @Published var findingLeftovers = false
    @Published var working = false
    @Published var message: String?
    @Published var sort: Sort = .size

    enum Sort: String, CaseIterable { case size = "Dung lượng", unused = "Lâu không dùng", name = "Tên"
        var title: String {
            switch self {
            case .size: String(localized: "Dung lượng")
            case .unused: String(localized: "Lâu không dùng")
            case .name: String(localized: "Tên")
            }
        }
    }

    var sorted: [AppInfo] {
        switch sort {
        case .size: apps.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
        case .unused: apps.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        case .name: apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    nonisolated static func listApps() -> [AppInfo] {
        let fm = FileManager.default
        var paths: [String] = []
        for root in ["/Applications", "\(NSHomeDirectory())/Applications"] {
            for e in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
                let p = "\(root)/\(e)"
                if e.hasSuffix(".app") { paths.append(p) }
                else if !e.hasPrefix("."), let sub = try? fm.contentsOfDirectory(atPath: p) {
                    paths += sub.filter { $0.hasSuffix(".app") }.map { "\(p)/\($0)" }
                }
            }
        }
        let me = Bundle.main.bundleIdentifier
        return paths.compactMap { p in
            guard let b = Bundle(path: p), let id = b.bundleIdentifier, !id.hasPrefix("com.apple."), id != me else { return nil }
            let name = (b.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? (b.infoDictionary?["CFBundleName"] as? String)
                ?? ((p as NSString).lastPathComponent as NSString).deletingPathExtension
            let v = b.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            return AppInfo(path: p, name: name, bundleID: id, version: v)
        }
    }

    nonisolated static func lastUsed(_ path: String) -> Date? {
        guard let item = MDItemCreate(nil, path as CFString),
              let d = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date else { return nil }
        return d
    }

    func load() {
        guard !loading else { return }
        loading = true
        Task {
            var list = await Task.detached { AppsModel.listApps() }.value
            for i in list.indices { list[i].lastUsed = AppsModel.lastUsed(list[i].path) }
            apps = list
            loading = false
            loaded = true
            // Tính dung lượng dần dần
            for i in list.indices {
                let p = list[i].path
                let s = await Task.detached(priority: .utility) { Shell.size(of: [p]) }.value
                if let j = apps.firstIndex(where: { $0.path == p }) { apps[j].size = s }
            }
        }
    }

    nonisolated static func findLeftovers(_ app: AppInfo) -> [Leftover] {
        let fm = FileManager.default
        let lib = "\(NSHomeDirectory())/Library"
        let dirs = ["Application Support", "Caches", "Preferences", "Preferences/ByHost", "Containers", "Group Containers",
                    "Saved Application State", "Logs", "HTTPStorages", "WebKit", "Cookies", "LaunchAgents",
                    "Application Scripts", "Application Support/CrashReporter"]
        let id = app.bundleID.lowercased()
        let name = app.name.lowercased()
        let compact = name.replacingOccurrences(of: " ", with: "")
        func matches(_ e: String, deep: Bool) -> Bool {
            let low = e.lowercased()
            let base = (low as NSString).deletingPathExtension
            if low.contains(id) || base == name { return true }
            guard compact.count >= 5 else { return false }
            // Tên kèm số phiên bản, ví dụ GoLand2026.2 trong thư mục JetBrains
            return base == compact || (deep && base.hasPrefix(compact) && base.dropFirst(compact.count).allSatisfy { $0.isNumber || $0 == "." })
        }
        var out: [Leftover] = []
        for d in dirs {
            let dir = "\(lib)/\(d)"
            for e in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                let p = "\(dir)/\(e)"
                if matches(e, deep: false) { out.append(Leftover(path: p, size: FileOps.allocatedSize(p))); continue }
                // Tìm thêm 1 cấp trong thư mục của hãng (Application Support/JetBrains/GoLand2026.2)
                guard ["Application Support", "Caches", "Logs"].contains(d) else { continue }
                for sub in (try? fm.contentsOfDirectory(atPath: p)) ?? [] where matches(sub, deep: true) {
                    out.append(Leftover(path: "\(p)/\(sub)", size: FileOps.allocatedSize("\(p)/\(sub)")))
                }
            }
        }
        return out.sorted { $0.size > $1.size }
    }

    func select(_ app: AppInfo) {
        selected = app
        leftovers = []
        message = nil
        findingLeftovers = true
        Task {
            let r = await Task.detached { AppsModel.findLeftovers(app) }.value
            if selected?.path == app.path { leftovers = r }
            findingLeftovers = false
        }
    }

    /// includeApp = false: chỉ xoá dữ liệu (đưa app về như mới cài).
    func uninstall(includeApp: Bool) {
        guard let app = selected else { return }
        working = true
        Task {
            for ra in NSWorkspace.shared.runningApplications where ra.bundleIdentifier == app.bundleID { ra.terminate() }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            var paths = leftovers.filter(\.selected).map(\.path)
            if includeApp { paths.insert(app.path, at: 0) }
            let failed = await FileOps.trash(paths)
            working = false
            if failed.isEmpty {
                message = includeApp ? String(localized: "Đã gỡ \(app.name). File nằm trong Thùng rác.") : String(localized: "Đã xoá dữ liệu của \(app.name).")
                if includeApp { apps.removeAll { $0.path == app.path }; selected = nil } else { select(app) }
            } else {
                message = String(localized: "Không xoá được \(failed.count) mục. App có thể đang chạy hoặc cần quyền admin.")
            }
        }
    }
}

struct UninstallerView: View {
    @ObservedObject var m = AppsModel.shared
    @State private var confirm: Bool? = nil   // true = gỡ app, false = chỉ xoá dữ liệu

    var body: some View {
        ModulePage(title: String(localized: "Gỡ cài đặt"), subtitle: String(localized: "Xoá app cùng file sót lại trong ~/Library. Mọi thứ được chuyển vào Thùng rác.")) {
            Picker("", selection: $m.sort) { ForEach(AppsModel.Sort.allCases, id: \.self) { Text($0.title) } }
                .pickerStyle(.segmented).frame(width: 300)
        } content: {
            if m.loading && m.apps.isEmpty {
                BusyView(text: String(localized: "Đang đọc danh sách app..."))
            } else {
                HStack(alignment: .top, spacing: 16) {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(m.sorted.enumerated()), id: \.element.id) { i, a in appRow(a).staggerIn(i) }
                        }
                    }
                    .scrollIndicators(.never)
                    .frame(width: 330)
                    .animation(Motion.spring, value: m.sort)
                    detail
                }
            }
        }
        .onAppear { if !m.loaded { m.load() } }
        .alert(confirm == true ? "Gỡ \(m.selected?.name ?? "")?" : "Xoá dữ liệu của \(m.selected?.name ?? "")?",
               isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button(confirm == true ? String(localized: "button.uninstall", defaultValue: "Gỡ cài đặt") : String(localized: "Xoá dữ liệu"), role: .destructive) { m.uninstall(includeApp: confirm == true) }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text(confirm == true ? "App và các file đã chọn được chuyển vào Thùng rác. App đang mở sẽ được thoát trước."
                                 : "App giữ nguyên, chỉ xoá cài đặt và dữ liệu đã chọn. App sẽ như mới cài.")
        }
    }

    private func appRow(_ a: AppInfo) -> some View {
        let sel = m.selected?.path == a.path
        return Button { m.select(a) } label: {
            HStack(spacing: 10) {
                Image(nsImage: IconCache.shared.icon(for: a.path)).resizable().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(a.name).lineLimit(1)
                    Text(fmtAgo(a.lastUsed)).font(.caption)
                        .foregroundStyle(a.unused ? Color(hex: 0xF2B544) : Theme.text2)
                }
                Spacer()
                Text(a.size.map(fmtBytes) ?? "...").monospacedDigit().foregroundStyle(Theme.text2)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(sel ? 0.12 : 0)))
            .contentShape(Rectangle())
            .animation(Motion.snappy, value: sel)
        }
        .buttonStyle(PressableStyle(scale: 0.98))
    }

    @ViewBuilder private var detail: some View {
        if let a = m.selected {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Image(nsImage: IconCache.shared.icon(for: a.path)).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(a.name).font(.system(size: 24, weight: .bold, design: .rounded))
                        Text("Phiên bản \(a.version). Dùng lần cuối: \(fmtAgo(a.lastUsed))").foregroundStyle(Theme.text2)
                        Text(FileOps.pretty(a.path)).font(.caption).foregroundStyle(Theme.text2)
                    }
                }
                Text("File sót lại trong ~/Library").font(.headline)
                if m.findingLeftovers {
                    ProgressView().controlSize(.small)
                } else if m.leftovers.isEmpty {
                    Text("Không tìm thấy file nào.").foregroundStyle(Theme.text2)
                }
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach($m.leftovers) { $l in FileLine(path: l.path, size: l.size, selected: $l.selected) }
                    }
                }
                .scrollIndicators(.never)
                if let msg = m.message { Text(msg).foregroundStyle(Theme.mint) }
                let total = (a.size ?? 0) + m.leftovers.filter(\.selected).reduce(0) { $0 + $1.size }
                HStack {
                    Text("Tổng \(fmtBytes(total))").foregroundStyle(Theme.text2)
                    Spacer()
                    PillButton(title: String(localized: "Chỉ xoá dữ liệu"), tint: nil) { confirm = false }
                        .disabled(m.leftovers.filter(\.selected).isEmpty || m.working)
                    PillButton(title: m.working ? String(localized: "Đang gỡ...") : String(localized: "button.uninstall", defaultValue: "Gỡ cài đặt"), icon: "trash", danger: true) { confirm = true }
                        .disabled(m.working)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.glass))
            .id(a.path)
            .transition(.opacity.combined(with: .offset(x: 20)))
            .animation(Motion.spring, value: m.leftovers.count)
        } else {
            EmptyHint(icon: "app.badge.checkmark", title: String(localized: "Chọn một app"),
                      detail: String(localized: "\(m.apps.count) app. Chữ màu vàng là app không dùng hơn 3 tháng."))
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.glass))
        }
    }
}

// MARK: - Cập nhật app (Homebrew cask và App Store)

struct Outdated: Identifiable {
    var id: String { source + token }
    let source: String       // "brew" / "mas"
    let token: String        // tên cask hoặc id App Store
    let name: String
    let installed: String
    let latest: String
    var state: CleanItem.State = .idle
}

@MainActor
final class UpdaterModel: ObservableObject {
    static let shared = UpdaterModel()
    @Published var items: [Outdated] = []
    @Published var loading = false
    @Published var loaded = false
    @Published var hasBrew = true

    func load() {
        guard !loading else { return }
        loading = true
        Task {
            let (list, brew) = await Task.detached { () -> ([Outdated], Bool) in
                var out: [Outdated] = []
                let brew = Shell.has("brew")
                if brew {
                    let j = Shell.run("brew outdated --cask --greedy --json=v2").output
                    if let d = j.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                       let casks = obj["casks"] as? [[String: Any]] {
                        for c in casks {
                            let tok = c["name"] as? String ?? ""
                            let inst = (c["installed_versions"] as? [String])?.first ?? ""
                            out.append(Outdated(source: "brew", token: tok, name: tok, installed: inst, latest: c["current_version"] as? String ?? ""))
                        }
                    }
                }
                if Shell.has("mas") {
                    for line in Shell.run("mas outdated").output.split(separator: "\n") {
                        // 497799835 Xcode (15.0 -> 15.1)
                        let s = String(line)
                        guard let sp = s.firstIndex(of: " "), let lp = s.lastIndex(of: "(") else { continue }
                        let id = String(s[..<sp])
                        let name = s[s.index(after: sp)..<lp].trimmingCharacters(in: .whitespaces)
                        let vers = s[s.index(after: lp)...].dropLast().components(separatedBy: " -> ")
                        out.append(Outdated(source: "mas", token: id, name: name, installed: vers.first ?? "", latest: vers.last ?? ""))
                    }
                }
                return (out, brew)
            }.value
            items = list; hasBrew = brew; loading = false; loaded = true
        }
    }

    func update(_ ids: [String]) {
        Task {
            for id in ids {
                guard let i = items.firstIndex(where: { $0.id == id }) else { continue }
                items[i].state = .running
                let it = items[i]
                let cmd = it.source == "brew" ? "brew upgrade --cask \(FileOps.q(it.token))" : "mas upgrade \(FileOps.q(it.token))"
                let ok = await Task.detached { Shell.run(cmd).status == 0 }.value
                if let j = items.firstIndex(where: { $0.id == id }) { items[j].state = ok ? .done : .failed }
            }
        }
    }
}

struct UpdaterView: View {
    @ObservedObject var m = UpdaterModel.shared

    var body: some View {
        ModulePage(title: String(localized: "Cập nhật"), subtitle: String(localized: "App cài qua Homebrew và App Store có bản mới.")) {
            HStack {
                Button { m.load() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).foregroundStyle(Theme.text2)
                if !m.items.isEmpty {
                    PillButton(title: String(localized: "Cập nhật tất cả")) { m.update(m.items.filter { $0.state == .idle }.map(\.id)) }
                }
            }
        } content: {
            if m.loading {
                BusyView(text: String(localized: "Đang hỏi Homebrew và App Store..."))
            } else if !m.hasBrew && m.items.isEmpty {
                EmptyHint(icon: "mug", title: String(localized: "Chưa cài Homebrew"), detail: String(localized: "App này kiểm tra bản mới qua Homebrew (brew.sh) và mas."))
            } else if m.items.isEmpty {
                EmptyHint(icon: "checkmark.seal", title: String(localized: "Tất cả app đã mới nhất"), detail: String(localized: "App tự cập nhật (Chrome, Zalo...) không có trong danh sách này."))
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Array(m.items.enumerated()), id: \.element.id) { i, it in
                            HStack(spacing: 12) {
                                Image(systemName: it.source == "brew" ? "mug.fill" : "bag.fill").foregroundStyle(Theme.mint).frame(width: 26)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(it.name).font(.body.weight(.medium))
                                    Text("\(it.installed) → \(it.latest)").font(.caption).foregroundStyle(Theme.text2)
                                }
                                Spacer()
                                switch it.state {
                                case .idle: PillButton(title: String(localized: "button.update", defaultValue: "Cập nhật"), tint: nil) { m.update([it.id]) }
                                case .running: ProgressView().controlSize(.small)
                                case .done: Label("Xong", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.mint)
                                case .failed: Label("Lỗi", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color(hex: 0xF2B544))
                                }
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.glass))
                            .staggerIn(i, dx: 30, dy: 0)
                            .animation(Motion.spring, value: it.state)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .onAppear { if !m.loaded { m.load() } }
    }
}
