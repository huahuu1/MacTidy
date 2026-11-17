import AppKit
import Foundation
import SwiftUI

/// Thao tác file dùng chung. Mọi thao tác xoá file của người dùng đều chuyển vào Thùng rác.
enum FileOps {
    static let home = NSHomeDirectory()

    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Chuyển vào Thùng rác. Trả về các đường dẫn không chuyển được.
    static func trash(_ paths: [String]) async -> [String] {
        var failed: [String] = []
        for p in paths where FileManager.default.fileExists(atPath: p) {
            do { try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil) }
            catch { failed.append(p) }
        }
        if failed.isEmpty { return [] }
        // File của root (ví dụ app trong /Applications): nhờ Finder xoá, Finder tự hỏi mật khẩu.
        let rest = failed
        return await MainActor.run { finderDelete(rest) }
    }

    @MainActor
    static func finderDelete(_ paths: [String]) -> [String] {
        let list = paths.map { "POSIX file \"\(asEscape($0))\"" }.joined(separator: ", ")
        var err: NSDictionary?
        NSAppleScript(source: "tell application \"Finder\" to delete {\(list)}")?.executeAndReturnError(&err)
        return paths.filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Chạy lệnh cần quyền admin. macOS tự hiện hộp thoại nhập mật khẩu.
    @MainActor
    static func runAdmin(_ cmd: String) -> (ok: Bool, message: String) {
        var err: NSDictionary?
        let out = NSAppleScript(source: "do shell script \"\(asEscape(cmd))\" with administrator privileges")?
            .executeAndReturnError(&err)
        if let err { return (false, err[NSAppleScript.errorMessage] as? String ?? String(localized: "Lỗi")) }
        return (true, out?.stringValue ?? "")
    }

    static func asEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    @MainActor static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Dung lượng thật trên ổ (theo block), không bị lừa bởi file sparse.
    static func allocatedSize(_ path: String) -> Int64 {
        var st = stat()
        guard lstat(path, &st) == 0 else { return 0 }
        if (st.st_mode & S_IFMT) == S_IFDIR { return Shell.size(of: [path]) }
        return Int64(st.st_blocks) * 512
    }

    static func pretty(_ path: String) -> String {
        path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

private let viDate: DateFormatter = {
    let f = DateFormatter(); f.locale = Locale(identifier: "vi_VN"); f.dateFormat = "dd/MM/yyyy"; return f
}()

func fmtDate(_ d: Date?) -> String {
    guard let d else { return String(localized: "Chưa rõ") }
    return viDate.string(from: d)
}

func fmtAgo(_ d: Date?) -> String {
    guard let d else { return String(localized: "Chưa dùng") }
    let days = Int(Date().timeIntervalSince(d) / 86_400)
    if days < 1 { return String(localized: "Hôm nay") }
    if days < 30 { return String(localized: "\(days) ngày trước") }
    if days < 365 { return String(localized: "\(days / 30) tháng trước") }
    return String(localized: "\(days / 365) năm trước")
}

// MARK: - UI dùng chung cho các trang module

struct ModulePage<Content: View, Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .bottom) {
                PageHeader(title: title, subtitle: subtitle)
                Spacer()
                trailing
            }
            content
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct PillButton: View {
    let title: String
    var icon: String? = nil
    var tint: Color? = Theme.mint
    var danger = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon) }
                Text(title)
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(tint == nil ? Color.white : Color.black.opacity(0.85))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(danger ? Color(hex: 0xFF6B5B) : (tint ?? Color.white.opacity(0.12))))
        }
        .buttonStyle(PressableStyle())
    }
}

struct BusyView: View {
    let text: String
    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(text).foregroundStyle(Theme.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyHint: View {
    let icon: String
    let title: String
    let detail: String
    var action: (String, () -> Void)? = nil
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                BreathingGlow(color: Theme.mint, size: 70)
                Image(systemName: icon).font(.system(size: 54, weight: .light)).foregroundStyle(Theme.mint)
                    .symbolEffect(.bounce, options: .nonRepeating, value: title)
            }
            .staggerIn(0)
            Text(title).font(.system(size: 22, weight: .bold, design: .rounded)).staggerIn(1)
            Text(detail).foregroundStyle(Theme.text2).multilineTextAlignment(.center).frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)
            if let action { OrbButton(title: action.0, size: 96, action: action.1).padding(.top, 8) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Thanh dưới cùng: tổng đã chọn + nút hành động.
struct SelectionBar: View {
    let text: String
    let button: String
    var danger = false
    var disabled = false
    let action: () -> Void
    var body: some View {
        HStack {
            Text(text).foregroundStyle(Theme.text2)
            Spacer()
            PillButton(title: button, icon: danger ? "trash" : nil, danger: danger, action: action)
                .disabled(disabled).opacity(disabled ? 0.4 : 1)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.22)))
    }
}

/// Một dòng file có ô chọn.
struct FileLine: View {
    let path: String
    let size: Int64
    var note: String? = nil
    @Binding var selected: Bool
    var askAI = false
    @State private var hover = false
    @ObservedObject private var ai = AIAdvisor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 10) {
            Toggle("", isOn: $selected).labelsHidden().toggleStyle(.checkbox)
            Image(nsImage: IconCache.shared.icon(for: path)).resizable().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text((path as NSString).lastPathComponent).lineLimit(1)
                Text(FileOps.pretty((path as NSString).deletingLastPathComponent))
                    .font(.caption).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.middle)
            }
            .layoutPriority(1)
            Spacer()
            if let note { Text(note).font(.caption).foregroundStyle(Theme.text2).lineLimit(1).fixedSize() }
            if askAI {
                AskAIButton(key: "file-" + path, title: (path as NSString).lastPathComponent, paths: [path],
                            action: "chuyển file này vào Thùng rác", size: size)
                    .opacity(hover || ai.states["file-" + path] != nil ? 1 : 0)
            }
            Text(fmtBytes(size)).monospacedDigit().frame(width: 86, alignment: .trailing)
            Button { FileOps.reveal(path) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.plain).foregroundStyle(Theme.text2).help("Hiện trong Finder")
                .opacity(hover ? 1 : 0.4)
        }
        if askAI { AIVerdictView(key: "file-" + path) }
        }
        .onChange(of: ai.states["file-" + path]) { _, s in
            if case .done(let v, _) = s, v.verdict == "in_use" { selected = false }
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(hover ? 0.06 : 0)))
        .onHover { hover = $0 }
        .animation(Motion.snappy, value: hover)
    }
}
