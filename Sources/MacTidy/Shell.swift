import Foundation

/// Chạy lệnh shell với PATH đầy đủ (app GUI không có PATH của Terminal).
enum Shell {
    static let envPath: String = {
        let home = NSHomeDirectory()
        var parts = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.orbstack/bin",
                     "\(home)/go/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let fm = FileManager.default
        let nvm = "\(home)/.nvm/versions/node"
        if let vs = try? fm.contentsOfDirectory(atPath: nvm) {
            parts.insert(contentsOf: vs.sorted().reversed().map { "\(nvm)/\($0)/bin" }, at: 0)
        }
        let gvm = "\(home)/.gvm/gos"
        if let vs = try? fm.contentsOfDirectory(atPath: gvm) {
            parts.append(contentsOf: vs.sorted().reversed().map { "\(gvm)/\($0)/bin" })
        }
        return parts.joined(separator: ":")
    }()

    @discardableResult
    static func run(_ command: String) -> (output: String, status: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-f", "-c", command]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = envPath
        env["LANG"] = "en_US.UTF-8"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return ("", -1) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), p.terminationStatus)
    }

    static func has(_ tool: String) -> Bool { run("command -v \(tool)").status == 0 }

    /// Tổng dung lượng (byte) của các đường dẫn, dùng du.
    static func size(of paths: [String]) -> Int64 {
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return 0 }
        let quoted = existing.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        let out = run("du -sk \(quoted) 2>/dev/null | awk '{s+=$1} END{print s+0}'").output
        return (Int64(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) * 1024
    }
}

private let gbFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter(); f.countStyle = .file; f.allowedUnits = [.useGB]; return f
}()
private let mbFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter(); f.countStyle = .file; f.allowedUnits = [.useMB, .useKB]; return f
}()

func fmtBytes(_ b: Int64) -> String {
    (b >= 1_000_000_000 ? gbFormatter : mbFormatter).string(fromByteCount: b)
}

func fmtGB(_ b: UInt64) -> String { String(format: "%.1f GB", Double(b) / 1_073_741_824) }

func fmtSpeed(_ bps: Double) -> String {
    if bps >= 1_000_000 { return String(format: "%.1f MB/s", bps / 1_000_000) }
    if bps >= 1_000 { return String(format: "%.0f KB/s", bps / 1_000) }
    return String(format: "%.0f B/s", bps)
}
