import AppKit
import SwiftUI

/// Hỏi Claude Code (CLI `claude -p`) xem một mục có an toàn để xoá không.
///
/// An toàn:
/// - App tự chạy các lệnh CHỈ ĐỌC để lấy dữ kiện (lsof, ps, dung lượng, file sửa gần nhất) rồi đưa cho Claude.
/// - Claude chỉ có Read, Glob, Grep. Không có Bash, Edit, Write, web. `--permission-mode dontAsk`
///   từ chối mọi thứ ngoài danh sách mà không hỏi.
/// - Claude chỉ đưa ý kiến. Xoá hay không vẫn do người dùng bấm.
struct AIVerdict: Decodable, Equatable {
    let verdict: String      // safe | caution | in_use
    let summary: String
    let evidence: [String]
}

@MainActor
final class AIAdvisor: ObservableObject {
    static let shared = AIAdvisor()

    enum State: Equatable {
        case running(String)
        case done(AIVerdict, cost: Double)
        case failed(String)
    }

    @Published var states: [String: State] = [:]
    @Published var totalCost: Double = 0

    nonisolated static let claudePath: String? = {
        let home = NSHomeDirectory()
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
        if let p = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return p }
        let w = Shell.run("command -v claude").output.trimmingCharacters(in: .whitespacesAndNewlines)
        return w.isEmpty ? nil : w
    }()

    var available: Bool { Self.claudePath != nil }

    nonisolated static let schema = """
    {"type":"object","properties":{"verdict":{"type":"string","enum":["safe","caution","in_use"]},\
    "summary":{"type":"string"},"evidence":{"type":"array","items":{"type":"string"}}},\
    "required":["verdict","summary","evidence"],"additionalProperties":false}
    """

    /// key: id của dòng trong UI. paths: các đường dẫn sẽ bị xoá. action: mô tả việc xoá (lệnh hoặc "chuyển vào Thùng rác").
    func ask(key: String, title: String, paths: [String], action: String, size: Int64) {
        guard let claude = Self.claudePath else { states[key] = .failed(String(localized: "Chưa cài Claude Code (lệnh `claude`).")); return }
        if case .running = states[key] { return }
        states[key] = .running(String(localized: "Đang thu thập dữ kiện..."))
        Task {
            let facts = await Task.detached(priority: .userInitiated) { AIAdvisor.gatherFacts(paths) }.value
            states[key] = .running(String(localized: "Claude đang phân tích..."))
            let prompt = AIAdvisor.prompt(title: title, paths: paths, action: action, size: size, facts: facts)
            let r = await Task.detached(priority: .userInitiated) { AIAdvisor.runClaude(claude, prompt: prompt) }.value
            switch r {
            case .success(let (v, cost)):
                states[key] = .done(v, cost: cost)
                totalCost += cost
            case .failure(let e):
                states[key] = .failed(e.message)
            }
        }
    }

    // MARK: - Dữ kiện do app tự lấy (chỉ đọc)

    nonisolated static func gatherFacts(_ paths: [String]) -> String {
        let shown = Array(paths.prefix(12))
        var out: [String] = []
        // File đang được process nào mở: lấy toàn bộ lsof một lần rồi lọc theo đường dẫn
        let lsof = Shell.run("lsof -n -w -F pcn 2>/dev/null").output
        var openBy: [String: Set<String>] = [:]
        var curCmd = ""
        for line in lsof.split(separator: "\n") {
            if line.hasPrefix("c") { curCmd = String(line.dropFirst()) }
            else if line.hasPrefix("n") {
                let f = String(line.dropFirst())
                for p in shown where f.hasPrefix(p) { openBy[p, default: []].insert(curCmd) }
            }
        }
        for p in shown {
            let q = FileOps.q(p)
            let size = Shell.run("du -sh \(q) 2>/dev/null | cut -f1").output.trimmingCharacters(in: .whitespacesAndNewlines)
            let mod = Shell.run("stat -f '%Sm' -t '%Y-%m-%d %H:%M' \(q) 2>/dev/null").output.trimmingCharacters(in: .whitespacesAndNewlines)
            let recent = Shell.run("find \(q) -type f -mtime -2 2>/dev/null | head -5").output
                .split(separator: "\n").map { FileOps.pretty(String($0)) }
            let users = openBy[p].map { $0.sorted().joined(separator: ", ") } ?? "không có"
            var s = "- \(FileOps.pretty(p)): \(size.isEmpty ? "?" : size), sửa lần cuối \(mod.isEmpty ? "?" : mod). Process đang mở file bên trong: \(users)."
            if !recent.isEmpty { s += " File sửa trong 2 ngày qua: \(recent.joined(separator: "; "))." }
            out.append(s)
        }
        if paths.count > shown.count { out.append("- ... và \(paths.count - shown.count) đường dẫn khác cùng loại.") }
        let apps = NSWorkspace.shared.runningApplications.compactMap(\.localizedName).sorted().joined(separator: ", ")
        out.append("App đang mở: \(apps).")
        return out.joined(separator: "\n")
    }

    nonisolated static func prompt(title: String, paths: [String], action: String, size: Int64, facts: String) -> String {
        """
        Bạn là trợ lý kiểm tra an toàn trước khi dọn dẹp ổ đĩa trên macOS của một lập trình viên.
        Mục người dùng định dọn: "\(title)", khoảng \(fmtBytes(size)).
        Cách xoá: \(action)

        Dữ kiện app đã đo (chỉ đọc):
        \(facts)

        Hãy đánh giá xoá mục này có an toàn không: có app hay project nào đang dùng, có dữ liệu không tạo lại được không, \
        xoá xong có gây lỗi hoặc phải tải lại nhiều không. Bạn chỉ có công cụ Read, Glob, Grep để xem thêm file nếu cần \
        (ví dụ file cấu hình, README trong thư mục). Không cần xem hết, chỉ xem khi giúp kết luận.

        \(AppLanguage.isEnglish ? "Answer in English, short and plain. Write summary and evidence in English." : "Trả lời tiếng Việt, ngắn gọn, dùng từ thông dụng, giữ thuật ngữ kỹ thuật tiếng Anh.")
        verdict: "safe" nếu xoá không mất gì quan trọng; "caution" nếu nên xem lại hoặc nên làm thêm bước trước khi xoá; \
        "in_use" nếu đang được dùng và xoá lúc này sẽ gây lỗi hoặc mất dữ liệu.
        summary: 2 đến 4 câu, nói rõ nên làm gì. evidence: 2 đến 5 dữ kiện cụ thể dẫn tới kết luận.
        """
    }

    // MARK: - Gọi Claude Code CLI

    struct RunError: Error { let message: String }

    nonisolated static func runClaude(_ claude: String, prompt: String) -> Result<(AIVerdict, Double), RunError> {
        let dir = NSTemporaryDirectory() + "mactidy-ai"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        p.arguments = [
            "-p", prompt,
            "--output-format", "json",
            "--json-schema", schema,
            "--tools", "Read,Glob,Grep",
            "--allowedTools", "Read", "Glob", "Grep",
            "--disallowedTools", "Bash", "Edit", "Write", "NotebookEdit", "WebFetch", "WebSearch",
            "--permission-mode", "dontAsk",
            "--model", "claude-opus-5-5",
            "--effort", "medium",
            "--no-session-persistence",
            "--strict-mcp-config",
            "--setting-sources", "",
        ]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Shell.envPath
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return .failure(RunError(message: String(localized: "Không chạy được claude: \(error.localizedDescription)"))) }
        // Giới hạn 3 phút
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 180, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()

        struct Envelope: Decodable {
            let is_error: Bool?
            let result: String?
            let structured_output: AIVerdict?
            let total_cost_usd: Double?
        }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else {
            let msg = String(decoding: errData.isEmpty ? data : errData, as: UTF8.self)
            return .failure(RunError(message: msg.isEmpty ? String(localized: "Claude không trả lời (hết 3 phút hoặc chưa đăng nhập).") : String(msg.prefix(300))))
        }
        if env.is_error == true { return .failure(RunError(message: env.result ?? String(localized: "Claude báo lỗi."))) }
        if let v = env.structured_output { return .success((v, env.total_cost_usd ?? 0)) }
        if let r = env.result, let d = r.data(using: .utf8), let v = try? JSONDecoder().decode(AIVerdict.self, from: d) {
            return .success((v, env.total_cost_usd ?? 0))
        }
        return .failure(RunError(message: String(localized: "Không đọc được câu trả lời của Claude.")))
    }
}

// MARK: - Giao diện

struct AskAIButton: View {
    let key: String
    let title: String
    let paths: [String]
    let action: String
    let size: Int64
    @ObservedObject var ai = AIAdvisor.shared

    var body: some View {
        Button {
            ai.ask(key: key, title: title, paths: paths, action: action, size: size)
        } label: {
            HStack(spacing: 4) {
                if case .running = ai.states[key] { ProgressView().controlSize(.mini) } else { Image(systemName: "sparkles") }
                Text("Hỏi AI").lineLimit(1)
            }
            .fixedSize()
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Color(hex: 0xB79CFF).opacity(0.22)))
            .foregroundStyle(Color(hex: 0xD6C7FF))
        }
        .buttonStyle(PressableStyle())
        .help(ai.available ? "Nhờ Claude Code kiểm tra mục này có đang được dùng không (chỉ đọc, không xoá gì)"
                           : "Cần cài Claude Code: npm install -g @anthropic-ai/claude-code")
        .disabled(!ai.available || paths.isEmpty)
    }
}

/// Kết quả hiện ngay dưới dòng.
struct AIVerdictView: View {
    let key: String
    @ObservedObject var ai = AIAdvisor.shared
    @State private var showEvidence = false

    var body: some View {
        if let s = ai.states[key] {
            Group {
                switch s {
                case .running(let msg):
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(msg).foregroundStyle(Theme.text2) }
                case .failed(let msg):
                    Label(msg, systemImage: "exclamationmark.triangle").foregroundStyle(Color(hex: 0xF2B544))
                case .done(let v, let cost):
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            chip(v.verdict)
                            Spacer()
                            Text(String(format: "~%.2f USD", cost)).font(.caption2).foregroundStyle(Theme.text2)
                                .help("Chi phí lần hỏi này")
                        }
                        Text(v.summary).fixedSize(horizontal: false, vertical: true)
                        if !v.evidence.isEmpty {
                            Button(showEvidence ? "Ẩn căn cứ" : "Xem căn cứ (\(v.evidence.count))") {
                                withAnimation(Motion.spring) { showEvidence.toggle() }
                            }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(Theme.mint)
                            if showEvidence {
                                VStack(alignment: .leading, spacing: 3) {
                                    ForEach(v.evidence, id: \.self) { Text("• \($0)").font(.caption).foregroundStyle(Theme.text2) }
                                }
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }
                }
            }
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.18)))
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func chip(_ verdict: String) -> some View {
        let (text, color, icon): (String, Color, String) = switch verdict {
        case "safe": (String(localized: "An toàn để xoá"), Theme.mint, "checkmark.shield.fill")
        case "in_use": (String(localized: "Đang được dùng"), Color(hex: 0xFF6B5B), "hand.raised.fill")
        default: (String(localized: "Nên xem lại"), Color(hex: 0xF2B544), "exclamationmark.shield.fill")
        }
        return Label(text, systemImage: icon)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.2)))
            .foregroundStyle(color)
    }
}
