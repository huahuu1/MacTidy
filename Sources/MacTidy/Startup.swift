import AppKit
import SwiftUI

// MARK: - Mục khởi động: login item + launch agent/daemon

struct AgentItem: Identifiable {
    enum Scope: String { case user = "Của bạn", agent = "Mọi user", daemon = "Hệ thống"
        var title: String {
            switch self {
            case .user: String(localized: "Của bạn")
            case .agent: String(localized: "Mọi user")
            case .daemon: String(localized: "Hệ thống")
            }
        }
    }
    enum Sign { case apple, developer(String), unsigned, missing, unknown }

    var id: String { plist }
    let plist: String
    let label: String
    let program: String
    let scope: Scope
    var running: Bool
    var disabled: Bool
    var sign: Sign

    var suspicious: Bool {
        switch sign { case .unsigned, .missing: true; default: false }
    }
    var signText: String {
        switch sign {
        case .apple: "Apple"
        case .developer(let d): d
        case .unsigned: String(localized: "Chưa ký: không rõ nguồn gốc")
        case .missing: String(localized: "File chạy không còn: mục rác")
        case .unknown: String(localized: "Không kiểm tra được")
        }
    }
}

@MainActor
final class StartupModel: ObservableObject {
    static let shared = StartupModel()
    @Published var loginItems: [String] = []
    @Published var agents: [AgentItem] = []
    @Published var loading = false
    @Published var loaded = false
    @Published var message: String?

    var suspiciousCount: Int { agents.filter(\.suspicious).count }

    nonisolated static func signature(_ path: String) -> AgentItem.Sign {
        guard !path.isEmpty else { return .unknown }
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        let out = Shell.run("codesign -dv --verbose=2 \(FileOps.q(path)) 2>&1").output
        if out.contains("not signed") { return .unsigned }
        if let line = out.split(separator: "\n").first(where: { $0.hasPrefix("Authority=") }) {
            let a = line.replacingOccurrences(of: "Authority=", with: "")
            if a.contains("Apple") && !a.contains("Developer ID") && !a.contains("Apple Development") { return .apple }
            return .developer(a.replacingOccurrences(of: "Developer ID Application: ", with: ""))
        }
        if out.contains("Signature=adhoc") { return .unsigned }
        return .unknown
    }

    nonisolated static func scanAgents() -> [AgentItem] {
        let fm = FileManager.default
        let uid = getuid()
        let listOut = Shell.run("launchctl list").output
        let running = Set(listOut.split(separator: "\n").compactMap { l -> String? in
            let f = l.split(separator: "\t"); return f.count == 3 && f[0] != "-" ? String(f[2]) : nil
        })
        let disabledOut = Shell.run("launchctl print-disabled gui/\(uid)").output
        let disabled = Set(disabledOut.split(separator: "\n").compactMap { l -> String? in
            let s = l.trimmingCharacters(in: .whitespaces)
            guard s.hasSuffix("=> disabled") || s.hasSuffix("=> true"), let a = s.firstIndex(of: "\""),
                  let b = s[s.index(after: a)...].firstIndex(of: "\"") else { return nil }
            return String(s[s.index(after: a)..<b])
        })
        var out: [AgentItem] = []
        let dirs: [(String, AgentItem.Scope)] = [("\(NSHomeDirectory())/Library/LaunchAgents", .user),
                                                 ("/Library/LaunchAgents", .agent), ("/Library/LaunchDaemons", .daemon)]
        for (dir, scope) in dirs {
            for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".plist") {
                let p = "\(dir)/\(f)"
                guard let d = NSDictionary(contentsOfFile: p) as? [String: Any] else { continue }
                let label = d["Label"] as? String ?? (f as NSString).deletingPathExtension
                let prog = (d["Program"] as? String) ?? ((d["ProgramArguments"] as? [String])?.first ?? "")
                out.append(AgentItem(plist: p, label: label, program: prog, scope: scope,
                                     running: running.contains(label), disabled: disabled.contains(label),
                                     sign: signature(prog)))
            }
        }
        return out.sorted { ($0.suspicious ? 0 : 1, $0.scope.rawValue, $0.label) < ($1.suspicious ? 0 : 1, $1.scope.rawValue, $1.label) }
    }

    @MainActor static func readLoginItems() -> [String] {
        var err: NSDictionary?
        let r = NSAppleScript(source: "tell application \"System Events\" to get the name of every login item")?
            .executeAndReturnError(&err)
        guard let r, r.numberOfItems > 0 else { return [] }
        return (1...r.numberOfItems).compactMap { r.atIndex($0)?.stringValue }
    }

    func load() {
        guard !loading else { return }
        loading = true
        Task {
            loginItems = StartupModel.readLoginItems()
            agents = await Task.detached { StartupModel.scanAgents() }.value
            loading = false; loaded = true
        }
    }

    func removeLoginItem(_ name: String) {
        var err: NSDictionary?
        NSAppleScript(source: "tell application \"System Events\" to delete login item \"\(FileOps.asEscape(name))\"")?
            .executeAndReturnError(&err)
        loginItems = StartupModel.readLoginItems()
    }

    func toggle(_ a: AgentItem) {
        let uid = getuid()
        let cmd = a.disabled
            ? "launchctl enable gui/\(uid)/\(FileOps.q(a.label)); launchctl bootstrap gui/\(uid) \(FileOps.q(a.plist))"
            : "launchctl bootout gui/\(uid) \(FileOps.q(a.plist)); launchctl disable gui/\(uid)/\(FileOps.q(a.label))"
        Task {
            _ = await Task.detached { Shell.run(cmd) }.value
            loaded = false; load()
        }
    }

    func remove(_ a: AgentItem) {
        Task {
            if a.scope == .user {
                _ = await Task.detached { Shell.run("launchctl bootout gui/\(getuid()) \(FileOps.q(a.plist))") }.value
            }
            let failed = await FileOps.trash([a.plist])
            message = failed.isEmpty ? String(localized: "Đã chuyển \(a.label) vào Thùng rác. Mục của hệ thống sẽ dừng hẳn sau khi restart.")
                                     : String(localized: "Không xoá được \(a.label).")
            loaded = false; load()
        }
    }
}

struct StartupView: View {
    @ObservedObject var m = StartupModel.shared
    @State private var removeTarget: AgentItem?

    var body: some View {
        ModulePage(title: String(localized: "Mục khởi động"), subtitle: String(localized: "App tự mở khi đăng nhập và tiến trình chạy nền. Mục chưa ký hoặc mất file được đưa lên đầu.")) {
            HStack {
                Button { m.load() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).foregroundStyle(Theme.text2)
                PillButton(title: String(localized: "Mở cài đặt macOS"), tint: nil) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                }
            }
        } content: {
            if m.loading && m.agents.isEmpty {
                BusyView(text: String(localized: "Đang đọc mục khởi động và kiểm tra chữ ký..."))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let msg = m.message { Text(msg).foregroundStyle(Theme.mint) }
                        Glass(padding: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Mở khi đăng nhập (\(m.loginItems.count))").font(.headline).padding(8)
                                if m.loginItems.isEmpty {
                                    Text("Không có, hoặc macOS chưa cho phép MacTidy đọc. App đăng ký kiểu mới chỉ xem được trong cài đặt macOS.")
                                        .font(.callout).foregroundStyle(Theme.text2).padding(8)
                                }
                                ForEach(m.loginItems, id: \.self) { n in
                                    HStack {
                                        Image(systemName: "power").foregroundStyle(Theme.mint).frame(width: 24)
                                        Text(n)
                                        Spacer()
                                        Button("Bỏ") { m.removeLoginItem(n) }.buttonStyle(.plain).foregroundStyle(Theme.mint)
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 5)
                                }
                            }
                        }
                        Glass(padding: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Chạy nền (\(m.agents.count))").font(.headline).padding(8)
                                ForEach(Array(m.agents.enumerated()), id: \.element.id) { i, a in agentRow(a).staggerIn(i) }
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .onAppear { if !m.loaded { m.load() } }
        .alert("Xoá \(removeTarget?.label ?? "")?", isPresented: Binding(get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil } })) {
            Button("Chuyển vào Thùng rác", role: .destructive) { if let a = removeTarget { m.remove(a) } }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text("Xoá file .plist khởi động. App liên quan có thể tự tạo lại khi mở. Mục hệ thống cần mật khẩu admin.")
        }
    }

    private func agentRow(_ a: AgentItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: a.suspicious ? "exclamationmark.shield.fill" : (a.running ? "play.circle.fill" : "pause.circle"))
                .foregroundStyle(a.suspicious ? Color(hex: 0xFF6B5B) : (a.running ? Theme.mint : Theme.text2))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(a.label).lineLimit(1)
                Text(verbatim: "\(a.scope.title). \(a.signText)").font(.caption)
                    .foregroundStyle(a.suspicious ? Color(hex: 0xFF8A7A) : Theme.text2).lineLimit(1)
            }
            .layoutPriority(1)
            Spacer()
            if a.scope == .user {
                Toggle("", isOn: Binding(get: { !a.disabled }, set: { _ in m.toggle(a) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(Theme.mint)
                    .help(a.disabled ? "Đang tắt" : "Đang bật")
            }
            Button { FileOps.reveal(a.plist) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.plain).foregroundStyle(Theme.text2).help("Hiện trong Finder")
            Button { removeTarget = a } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(Theme.text2).help("Xoá")
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }
}

// MARK: - Bảo trì

struct MaintTask: Identifiable {
    let id: String
    let name: String
    let detail: String
    let icon: String
    let cmd: String
    let admin: Bool
    var selected = false
    var state: CleanItem.State = .idle
}

@MainActor
final class MaintenanceModel: ObservableObject {
    static let shared = MaintenanceModel()
    @Published var running = false
    @Published var message: String?
    @Published var tasks: [MaintTask] = {
        var t: [MaintTask] = [
            MaintTask(id: "dns", name: String(localized: "Xoá cache DNS"), detail: String(localized: "Sửa lỗi web không vào được sau khi đổi mạng, VPN hoặc file hosts"),
                      icon: "network", cmd: "dscacheutil -flushcache; killall -HUP mDNSResponder", admin: true, selected: true),
            MaintTask(id: "purge", name: String(localized: "Giải phóng bộ nhớ đệm ổ đĩa"), detail: String(localized: "Lệnh purge. Chỉ xoá cache file trong RAM, app đang chạy không bị ảnh hưởng"),
                      icon: "memorychip", cmd: "purge", admin: true, selected: true),
            MaintTask(id: "lsreg", name: String(localized: "Dựng lại danh sách \"Mở bằng\""), detail: String(localized: "Sửa menu Mở bằng bị trùng app hoặc icon sai"),
                      icon: "list.bullet.indent",
                      cmd: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user",
                      admin: false),
            MaintTask(id: "tm", name: String(localized: "Dọn snapshot Time Machine trên máy"), detail: String(localized: "Lấy lại dung lượng do snapshot cục bộ giữ"),
                      icon: "clock.arrow.circlepath", cmd: "tmutil thinlocalsnapshots / 999999999999 4", admin: true),
            MaintTask(id: "spotlight", name: String(localized: "Đánh chỉ mục lại Spotlight"), detail: String(localized: "Sửa Spotlight tìm không ra file. Máy sẽ chạy nặng 30 đến 60 phút sau đó"),
                      icon: "magnifyingglass", cmd: "mdutil -E /", admin: true),
            MaintTask(id: "qlcache", name: String(localized: "Xoá cache xem nhanh (Quick Look)"), detail: String(localized: "Sửa ảnh xem trước bị cũ hoặc sai"),
                      icon: "eye", cmd: "qlmanage -r cache; qlmanage -r", admin: false),
        ]
        if FileManager.default.fileExists(atPath: "/usr/sbin/periodic") {
            t.append(MaintTask(id: "periodic", name: String(localized: "Chạy script bảo trì của macOS"), detail: String(localized: "Dọn log và file tạm hệ thống (periodic daily, weekly, monthly)"),
                               icon: "gearshape.2", cmd: "periodic daily weekly monthly", admin: true))
        }
        return t
    }()

    func run() {
        running = true
        message = nil
        Task {
            let sel = tasks.indices.filter { tasks[$0].selected }
            for i in sel { tasks[i].state = .running }
            // Gộp lệnh admin để chỉ hỏi mật khẩu một lần
            let adminIdx = sel.filter { tasks[$0].admin }
            if !adminIdx.isEmpty {
                let cmd = adminIdx.map { tasks[$0].cmd }.joined(separator: "; ")
                let r = FileOps.runAdmin(cmd)
                for i in adminIdx { tasks[i].state = r.ok ? .done : .failed }
                if !r.ok { message = String(localized: "Chưa chạy các việc cần quyền admin: \(r.message)") }
            }
            for i in sel where !tasks[i].admin {
                let cmd = tasks[i].cmd
                let ok = await Task.detached { Shell.run(cmd).status == 0 }.value
                tasks[i].state = ok ? .done : .failed
            }
            running = false
        }
    }
}

struct MaintenanceView: View {
    @ObservedObject var m = MaintenanceModel.shared

    var body: some View {
        ModulePage(title: String(localized: "Bảo trì"), subtitle: String(localized: "Các lệnh sửa lỗi thường gặp của macOS. Việc cần quyền admin chỉ hỏi mật khẩu một lần.")) {
            EmptyView()
        } content: {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array($m.tasks.enumerated()), id: \.element.id) { i, $t in
                        HStack(spacing: 14) {
                            Image(systemName: t.icon).foregroundStyle(Theme.mint)
                                .frame(width: 38, height: 38)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(t.name).font(.body.weight(.medium))
                                    if t.admin { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(Theme.text2).help("Cần mật khẩu admin") }
                                }
                                Text(t.detail).font(.caption).foregroundStyle(Theme.text2)
                            }
                            Spacer()
                            switch t.state {
                            case .running: ProgressView().controlSize(.small)
                            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.mint)
                            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(hex: 0xF2B544))
                            case .idle: EmptyView()
                            }
                            Toggle("", isOn: $t.selected).labelsHidden().toggleStyle(.switch).tint(Theme.mint).disabled(m.running)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.glass))
                        .staggerIn(i, dx: 30, dy: 0)
                        .animation(Motion.spring, value: t.state)
                    }
                }
            }
            .scrollIndicators(.never)
            if let msg = m.message { Text(msg).foregroundStyle(Color(hex: 0xF2B544)) }
            SelectionBar(text: String(localized: "Đã chọn \(m.tasks.filter(\.selected).count) việc"), button: m.running ? String(localized: "Đang chạy...") : String(localized: "Chạy"),
                         disabled: m.running || !m.tasks.contains(where: \.selected)) { m.run() }
        }
    }
}
