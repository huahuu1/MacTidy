import Foundation

struct CleanItem: Identifiable {
    enum State { case idle, running, done, failed }

    let id: String
    let name: String
    let detail: String
    let icon: String
    var requires: String? = nil       // tool cần có
    var paths: [String] = []          // dùng du để tính dung lượng
    var dockerType: String? = nil     // "Images" / "Build Cache"
    var cleanCmd: String = ""         // lệnh xoá (cache tự tạo lại được)
    var trashPaths: [String] = []     // hoặc: chuyển các file này vào Thùng rác
    var warn = false
    var size: Int64 = 0
    var selected = true
    var state: State = .idle
}

@MainActor
final class Cleaner: ObservableObject {
    static let shared = Cleaner()
    @Published var scanningName = ""
    @Published var progress: Double = 0
    @Published var items: [CleanItem] = []
    @Published var scanning = false
    @Published var cleaning = false
    @Published var lastFreed: Int64?
    @Published var lastFailed: [String] = []
    @Published var cleanProgress: Double = 0
    @Published var scannedOnce = false

    var selectedSize: Int64 { items.filter(\.selected).reduce(0) { $0 + $1.size } }

    nonisolated static func definitions() -> [CleanItem] {
        let h = NSHomeDirectory()
        let fm = FileManager.default

        // Cache của từng app trong ~/Library/Caches (trừ của Apple và các mục đã tách riêng)
        let skip: Set<String> = ["go-build", "Homebrew", "Yarn", "pip"]
        let appCaches = ((try? fm.contentsOfDirectory(atPath: "\(h)/Library/Caches")) ?? [])
            .filter { !$0.hasPrefix("com.apple.") && !skip.contains($0) && !$0.hasPrefix(".") }
            .map { "\(h)/Library/Caches/\($0)" }

        // File cài đặt trong Downloads
        let installers = ((try? fm.contentsOfDirectory(atPath: "\(h)/Downloads")) ?? [])
            .filter { ["dmg", "pkg", "iso", "mpkg", "xip"].contains(($0 as NSString).pathExtension.lowercased()) }
            .map { "\(h)/Downloads/\($0)" }

        return [
            CleanItem(id: "appcache", name: String(localized: "Cache của các app"), detail: String(localized: "\(appCaches.count) app, trừ app của Apple. App tự tạo lại khi mở"),
                      icon: "square.stack.3d.up", paths: appCaches,
                      cleanCmd: "rm -rf " + appCaches.map(FileOps.q).joined(separator: " ")),
            CleanItem(id: "docker-build", name: "Docker build cache", detail: String(localized: "Cache khi build image"),
                      icon: "shippingbox", requires: "docker", dockerType: "Build Cache", cleanCmd: "docker builder prune -af"),
            CleanItem(id: "docker-images", name: String(localized: "Docker image không dùng"), detail: String(localized: "Image không gắn với container nào"),
                      icon: "shippingbox.fill", requires: "docker", dockerType: "Images", cleanCmd: "docker image prune -af"),
            CleanItem(id: "go", name: "Go build cache", detail: "~/Library/Caches/go-build",
                      icon: "hammer", paths: ["\(h)/Library/Caches/go-build"], cleanCmd: "rm -rf ~/Library/Caches/go-build"),
            CleanItem(id: "uv", name: "uv cache (Python)", detail: String(localized: "Bỏ qua nếu có app đang dùng uv"),
                      icon: "chevron.left.forwardslash.chevron.right", requires: "uv", paths: ["\(h)/.cache/uv"],
                      cleanCmd: "UV_LOCK_TIMEOUT=5 uv cache clean"),
            CleanItem(id: "npm", name: "npm cache", detail: "~/.npm/_cacache",
                      icon: "cube.box", paths: ["\(h)/.npm/_cacache"], cleanCmd: "rm -rf ~/.npm/_cacache"),
            CleanItem(id: "yarn", name: "Yarn cache", detail: "~/Library/Caches/Yarn",
                      icon: "cube.box", paths: ["\(h)/Library/Caches/Yarn"], cleanCmd: "rm -rf ~/Library/Caches/Yarn"),
            CleanItem(id: "pip", name: "pip cache", detail: "~/Library/Caches/pip",
                      icon: "cube.box", paths: ["\(h)/Library/Caches/pip"], cleanCmd: "rm -rf ~/Library/Caches/pip"),
            CleanItem(id: "brew", name: "Homebrew cache", detail: String(localized: "Bản tải về của brew"),
                      icon: "mug", requires: "brew", paths: ["\(h)/Library/Caches/Homebrew"], cleanCmd: "brew cleanup -s --prune=all"),
            CleanItem(id: "derived", name: "Xcode DerivedData", detail: String(localized: "Build cũ của Xcode"),
                      icon: "hammer.circle", paths: ["\(h)/Library/Developer/Xcode/DerivedData"],
                      cleanCmd: "rm -rf ~/Library/Developer/Xcode/DerivedData/*(N)"),
            CleanItem(id: "devicesupport", name: "Xcode iOS DeviceSupport", detail: String(localized: "Tự tải lại khi cắm iPhone"),
                      icon: "iphone", paths: ["\(h)/Library/Developer/Xcode/iOS DeviceSupport"],
                      cleanCmd: "rm -rf ~/Library/Developer/Xcode/iOS\\ DeviceSupport/*(N)"),
            CleanItem(id: "ipsw", name: String(localized: "Bản cập nhật iOS đã tải"), detail: String(localized: "File .ipsw cũ"),
                      icon: "arrow.down.app", paths: ["\(h)/Library/iTunes/iPhone Software Updates"],
                      cleanCmd: "rm -rf ~/Library/iTunes/iPhone\\ Software\\ Updates/*(N)"),
            CleanItem(id: "installers", name: String(localized: "File cài đặt trong Downloads"), detail: String(localized: "\(installers.count) file .dmg, .pkg, .iso. Chuyển vào Thùng rác"),
                      icon: "opticaldiscdrive", paths: installers, trashPaths: installers),
            CleanItem(id: "mail", name: String(localized: "File đính kèm Mail đã mở"), detail: String(localized: "Mail tự tải lại khi mở thư"),
                      icon: "paperclip", paths: ["\(h)/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"],
                      cleanCmd: "rm -rf ~/Library/Containers/com.apple.mail/Data/Library/Mail\\ Downloads/*(N)"),
            CleanItem(id: "logs", name: String(localized: "Log cũ hơn 14 ngày"), detail: String(localized: "Dung lượng là cả thư mục ~/Library/Logs"),
                      icon: "doc.text", paths: ["\(h)/Library/Logs"], cleanCmd: "find ~/Library/Logs -type f -mtime +14 -delete"),
            CleanItem(id: "iosbackup", name: String(localized: "Backup iPhone cũ"), detail: String(localized: "Kiểm tra trước khi xoá. Chuyển vào Thùng rác"),
                      icon: "externaldrive.badge.icloud", paths: ["\(h)/Library/Application Support/MobileSync/Backup"],
                      trashPaths: ((try? fm.contentsOfDirectory(atPath: "\(h)/Library/Application Support/MobileSync/Backup")) ?? [])
                          .map { "\(h)/Library/Application Support/MobileSync/Backup/\($0)" },
                      warn: true, selected: false),
            CleanItem(id: "trash", name: String(localized: "Thùng rác"), detail: String(localized: "Xoá vĩnh viễn, không lấy lại được"),
                      icon: "trash", paths: ["\(h)/.Trash"],
                      cleanCmd: "osascript -e 'tell application \"Finder\" to empty trash'", warn: true, selected: false),
        ]
    }

    func scan() { Task { await scanAsync() } }

    func scanAsync() async {
        guard !scanning, !cleaning else { return }
        scanning = true
        let result: [CleanItem] = await Task.detached(priority: .userInitiated) {
            var found: [CleanItem] = []
            let dockerOK = Shell.run("docker info >/dev/null 2>&1").status == 0
            let dockerDF = dockerOK ? Shell.run("docker system df --format '{{.Type}}\t{{.Reclaimable}}'").output : ""
            let defs = Cleaner.definitions()
            for (n, d) in defs.enumerated() {
                var item = d
                let label = item.name
                await MainActor.run {
                    Cleaner.shared.scanningName = label
                    Cleaner.shared.progress = Double(n) / Double(defs.count)
                }
                if let t = item.requires, !Shell.has(t) { continue }
                if let dt = item.dockerType {
                    guard dockerOK else { continue }
                    item.size = Cleaner.parseDocker(dockerDF, type: dt)
                } else {
                    item.size = Shell.size(of: item.paths)
                }
                if item.size >= 50 * 1024 * 1024 { found.append(item) }
            }
            return found.sorted { $0.size > $1.size }
        }.value
        items = result
        progress = 1
        scanning = false
        scannedOnce = true
    }

    nonisolated static func parseDocker(_ text: String, type: String) -> Int64 {
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t").map(String.init)
            guard f.count >= 2, f[0] == type else { continue }
            let v = f[1].split(separator: " ").first.map(String.init) ?? ""
            let num = Double(v.trimmingCharacters(in: CharacterSet(charactersIn: "0123456789.").inverted)) ?? 0
            let mult: Double = v.hasSuffix("TB") ? 1e12 : v.hasSuffix("GB") ? 1e9 : v.hasSuffix("MB") ? 1e6 : v.hasSuffix("kB") ? 1e3 : 1
            return Int64(num * mult)
        }
        return 0
    }

    func clean(monitor: SystemMonitor) { Task { await cleanAsync(monitor: monitor) } }

    func cleanAsync(monitor: SystemMonitor) async {
        guard !cleaning else { return }
        cleaning = true
        lastFreed = nil
        let before = monitor.diskFree
        let todo = items.enumerated().filter { $0.element.selected }.map { ($0.offset, $0.element) }
        cleanProgress = 0
        for (n, (idx, item)) in todo.enumerated() {
            items[idx].state = .running
            let ok: Bool
            if !item.trashPaths.isEmpty {
                ok = await FileOps.trash(item.trashPaths).isEmpty
            } else {
                let cmd = item.cleanCmd
                ok = await Task.detached { Shell.run(cmd).status == 0 }.value
            }
            items[idx].state = ok ? .done : .failed
            cleanProgress = Double(n + 1) / Double(max(1, todo.count))
        }
        lastFailed = items.filter { $0.state == .failed }.map(\.name)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        monitor.tick()
        lastFreed = max(0, monitor.diskFree - before)
        cleaning = false
        await scanAsync()
    }
}
