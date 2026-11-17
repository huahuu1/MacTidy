import AppKit
import SwiftUI

struct PrivacyItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let appName: String?          // app phải tắt trước khi xoá
    let files: [String]
    var size: Int64 = 0
    var selected = false
}

@MainActor
final class PrivacyModel: ObservableObject {
    static let shared = PrivacyModel()
    @Published var items: [PrivacyItem] = []
    @Published var loading = false
    @Published var loaded = false
    @Published var message: String?

    nonisolated static let browsers: [(name: String, app: String, root: String, flat: Bool)] = [
        ("Google Chrome", "Google Chrome", "Google/Chrome", false),
        ("Microsoft Edge", "Microsoft Edge", "Microsoft Edge", false),
        ("Brave", "Brave Browser", "BraveSoftware/Brave-Browser", false),
        (String(localized: "Cốc Cốc"), "CocCoc", "CocCoc/Browser", false),
        ("Vivaldi", "Vivaldi", "Vivaldi", false),
        ("Arc", "Arc", "Arc/User Data", false),
        ("Opera", "Opera", "com.operasoftware.Opera", true),
    ]

    nonisolated static func build() -> [PrivacyItem] {
        let fm = FileManager.default
        let support = "\(NSHomeDirectory())/Library/Application Support"
        var out: [PrivacyItem] = []
        for b in browsers {
            let root = "\(support)/\(b.root)"
            guard fm.fileExists(atPath: root) else { continue }
            let profiles: [String] = b.flat ? [root] :
                ((try? fm.contentsOfDirectory(atPath: root)) ?? [])
                    .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
                    .map { "\(root)/\($0)" }
            guard !profiles.isEmpty else { continue }
            func files(_ names: [String]) -> [String] {
                profiles.flatMap { p in names.map { "\(p)/\($0)" } }.filter { fm.fileExists(atPath: $0) }
            }
            let history = files(["History", "History-journal", "Visited Links", "Top Sites", "Top Sites-journal", "Shortcuts", "Shortcuts-journal"])
            let cookies = files(["Cookies", "Cookies-journal", "Network/Cookies", "Network/Cookies-journal"])
            let p = profiles.count > 1 ? " (\(profiles.count) profile)" : ""
            if !history.isEmpty {
                out.append(PrivacyItem(id: "\(b.name)-history", title: String(localized: "Lịch sử duyệt web \(b.name)\(p)"),
                                       detail: String(localized: "Trang đã xem, gợi ý trên thanh địa chỉ"), icon: "clock.arrow.circlepath",
                                       appName: b.app, files: history, size: history.reduce(0) { $0 + FileOps.allocatedSize($1) }))
            }
            if !cookies.isEmpty {
                out.append(PrivacyItem(id: "\(b.name)-cookies", title: "Cookie \(b.name)\(p)",
                                       detail: String(localized: "Xoá sẽ đăng xuất khỏi mọi website"), icon: "lock.open",
                                       appName: b.app, files: cookies, size: cookies.reduce(0) { $0 + FileOps.allocatedSize($1) }))
            }
        }
        let recentDir = "\(support)/com.apple.sharedfilelist"
        if let en = fm.enumerator(atPath: recentDir) {
            let recents = en.compactMap { $0 as? String }
                .filter { $0.contains("RecentDocuments") || $0.contains("RecentApplications") || $0.contains("RecentServers") }
                .filter { $0.hasSuffix(".sfl2") || $0.hasSuffix(".sfl3") || $0.hasSuffix(".sfl") }
                .map { "\(recentDir)/\($0)" }
            if !recents.isEmpty {
                out.append(PrivacyItem(id: "recents", title: String(localized: "Danh sách mở gần đây của macOS"),
                                       detail: String(localized: "Menu Apple > Mục gần đây, File > Mở gần đây"), icon: "list.bullet.rectangle",
                                       appName: nil, files: recents, size: recents.reduce(0) { $0 + FileOps.allocatedSize($1) }))
            }
        }
        let zsh = "\(NSHomeDirectory())/.zsh_history"
        if fm.fileExists(atPath: zsh) {
            out.append(PrivacyItem(id: "zsh", title: String(localized: "Lịch sử lệnh Terminal"), detail: String(localized: "~/.zsh_history. Mất các lệnh đã gõ trước đây"),
                                   icon: "terminal", appName: nil, files: [zsh], size: FileOps.allocatedSize(zsh)))
        }
        return out
    }

    func load() {
        guard !loading else { return }
        loading = true
        Task {
            let r = await Task.detached { PrivacyModel.build() }.value
            items = r; loading = false; loaded = true
        }
    }

    var runningBlockers: [String] {
        let names = Set(items.filter(\.selected).compactMap(\.appName))
        return NSWorkspace.shared.runningApplications.compactMap(\.localizedName).filter { names.contains($0) }
    }

    func quitBlockers() {
        let names = Set(runningBlockers)
        for app in NSWorkspace.shared.runningApplications where names.contains(app.localizedName ?? "") { app.terminate() }
    }

    func clean() {
        let paths = items.filter(\.selected).flatMap(\.files)
        Task {
            let failed = await FileOps.trash(paths)
            message = failed.isEmpty ? String(localized: "Đã chuyển \(paths.count) file vào Thùng rác.") : String(localized: "Không xoá được \(failed.count) file.")
            loaded = false
            load()
        }
    }
}

struct PrivacyView: View {
    @ObservedObject var m = PrivacyModel.shared
    @State private var confirm = false
    @State private var blockers: [String] = []

    var body: some View {
        ModulePage(title: String(localized: "Quyền riêng tư"), subtitle: String(localized: "Xoá dấu vết duyệt web và các danh sách mở gần đây. Mặc định không chọn mục nào.")) {
            Button { m.load() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).foregroundStyle(Theme.text2)
        } content: {
            if m.loading && m.items.isEmpty {
                BusyView(text: String(localized: "Đang tìm dữ liệu trình duyệt..."))
            } else if m.items.isEmpty {
                EmptyHint(icon: "hand.raised", title: String(localized: "Không có gì để xoá"), detail: String(localized: "Không tìm thấy trình duyệt Chromium nào."))
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(Array($m.items.enumerated()), id: \.element.id) { i, $item in
                            HStack(spacing: 14) {
                                Image(systemName: item.icon).foregroundStyle(Theme.mint)
                                    .frame(width: 38, height: 38)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).font(.body.weight(.medium))
                                    Text(item.detail).font(.caption).foregroundStyle(Theme.text2)
                                }
                                Spacer()
                                Text(fmtBytes(item.size)).monospacedDigit().foregroundStyle(Theme.text2)
                                Toggle("", isOn: $item.selected).labelsHidden().toggleStyle(.switch).tint(Theme.mint)
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.glass))
                            .staggerIn(i, dx: 30, dy: 0)
                        }
                    }
                }
                .scrollIndicators(.never)
                if let msg = m.message { Text(msg).foregroundStyle(Theme.mint) }
                SelectionBar(text: String(localized: "Safari không có ở đây vì macOS chặn app khác đọc dữ liệu Safari. Mật khẩu đã lưu không bị xoá."),
                             button: String(localized: "Xoá mục đã chọn"), danger: true, disabled: !m.items.contains(where: \.selected)) {
                    blockers = m.runningBlockers
                    confirm = true
                }
            }
        }
        .onAppear { if !m.loaded { m.load() } }
        .alert(blockers.isEmpty ? "Xoá các mục đã chọn?" : "Cần thoát \(blockers.joined(separator: ", ")) trước", isPresented: $confirm) {
            if blockers.isEmpty {
                Button("Chuyển vào Thùng rác", role: .destructive) { m.clean() }
            } else {
                Button("Thoát giúp tôi") { m.quitBlockers() }
            }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text(blockers.isEmpty ? "File được chuyển vào Thùng rác. Trình duyệt tự tạo file mới khi mở lại."
                                  : "Trình duyệt đang mở sẽ ghi đè lại dữ liệu. Thoát xong bấm Xoá lần nữa.")
        }
    }
}
