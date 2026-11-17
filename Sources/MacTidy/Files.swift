import AppKit
import CryptoKit
import SwiftUI

// MARK: - Bản đồ ổ đĩa

struct DiskNode: Identifiable {
    var id: String { path }
    let path: String
    let size: Int64
    let isDir: Bool
    var name: String { (path as NSString).lastPathComponent }
}

@MainActor
final class SpaceModel: ObservableObject {
    static let shared = SpaceModel()
    @Published var path = NSHomeDirectory()
    @Published var nodes: [DiskNode] = []
    @Published var total: Int64 = 0
    @Published var loading = false
    @Published var message: String?
    private var cache: [String: [DiskNode]] = [:]

    nonisolated static func children(_ dir: String) -> [DiskNode] {
        // du trên macOS không cho dùng -a cùng -d, nên đo từng mục con bằng -s (glob_dots: gồm cả file ẩn)
        let base = dir == "/" ? "" : dir
        let out = Shell.run("setopt null_glob glob_dots; du -skx -- \(FileOps.q(base))/* 2>/dev/null").output
        var nodes: [DiskNode] = []
        for line in out.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t"), let kb = Int64(line[..<tab]) else { continue }
            let p = String(line[line.index(after: tab)...])
            if p == dir || p == dir + "/" { continue }
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: p, isDirectory: &isDir)
            let pkg = p.hasSuffix(".app") || p.hasSuffix(".photoslibrary")
            nodes.append(DiskNode(path: p, size: kb * 1024, isDir: isDir.boolValue && !pkg))
        }
        return nodes.sorted { $0.size > $1.size }
    }

    func open(_ p: String, force: Bool = false) {
        path = p
        message = nil
        if !force, let c = cache[p] { nodes = c; total = c.reduce(0) { $0 + $1.size }; return }
        loading = true
        nodes = []
        Task {
            let r = await Task.detached(priority: .userInitiated) { SpaceModel.children(p) }.value
            cache[p] = r
            if path == p { nodes = r; total = r.reduce(0) { $0 + $1.size } }
            loading = false
        }
    }

    func up() {
        let parent = (path as NSString).deletingLastPathComponent
        if !parent.isEmpty { open(parent) }
    }

    func trash(_ n: DiskNode) {
        Task {
            let failed = await FileOps.trash([n.path])
            message = failed.isEmpty ? String(localized: "Đã chuyển \(n.name) vào Thùng rác.") : String(localized: "Không xoá được \(n.name).")
            cache = [:]
            open(path, force: true)
        }
    }
}

struct SpaceLensView: View {
    @ObservedObject var m = SpaceModel.shared
    @State private var trashTarget: DiskNode?
    private let palette: [Color] = [Theme.mint, Color(hex: 0x6CB8FF), Color(hex: 0xB79CFF), Color(hex: 0xF2B544),
                                    Color(hex: 0xFF8FB1), Color(hex: 0x7FE0E0)]

    var body: some View {
        ModulePage(title: String(localized: "Bản đồ ổ đĩa"), subtitle: String(localized: "Bấm vào thư mục để xem bên trong. Số là dung lượng thật trên ổ.")) {
            HStack(spacing: 8) {
                PillButton(title: String(localized: "Thư mục home"), tint: nil) { m.open(NSHomeDirectory()) }
                PillButton(title: String(localized: "Cả ổ"), tint: nil) { m.open("/") }
            }
        } content: {
            HStack(spacing: 8) {
                Button { m.up() } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain).disabled(m.path == "/")
                Text(FileOps.pretty(m.path)).font(.headline).lineLimit(1).truncationMode(.head)
                Spacer()
                if !m.loading { Text(fmtBytes(m.total)).font(.system(.title3, design: .rounded).weight(.semibold)) }
            }
            if m.loading {
                BusyView(text: String(localized: "Đang tính dung lượng \(FileOps.pretty(m.path)). Thư mục lớn có thể mất 1 đến 2 phút..."))
            } else {
                // Dải màu tỉ lệ cho 6 mục lớn nhất
                GeometryReader { g in
                    HStack(spacing: 2) {
                        ForEach(Array(m.nodes.prefix(6).enumerated()), id: \.offset) { i, n in
                            RoundedRectangle(cornerRadius: 6).fill(palette[i % palette.count])
                                .frame(width: max(3, g.size.width * CGFloat(Double(n.size) / Double(max(1, m.total)))))
                                .help("\(n.name): \(fmtBytes(n.size))")
                        }
                        RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1))
                    }
                }
                .frame(height: 22)
                .id(m.path)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .leading)))
                if let msg = m.message { Text(msg).foregroundStyle(Theme.mint) }
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(m.nodes.prefix(200).enumerated()), id: \.element.id) { i, n in row(n, color: i < 6 ? palette[i % palette.count] : Color.white.opacity(0.25)).staggerIn(i) }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .onAppear { if m.nodes.isEmpty && !m.loading { m.open(m.path) } }
        .alert("Chuyển \(trashTarget?.name ?? "") vào Thùng rác?", isPresented: Binding(get: { trashTarget != nil }, set: { if !$0 { trashTarget = nil } })) {
            Button("Chuyển vào Thùng rác", role: .destructive) { if let n = trashTarget { m.trash(n) } }
            Button("Huỷ", role: .cancel) {}
        } message: { Text("\(fmtBytes(trashTarget?.size ?? 0)). Có thể lấy lại từ Thùng rác.") }
    }

    private func row(_ n: DiskNode, color: Color) -> some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 8, height: 8)
            Image(nsImage: IconCache.shared.icon(for: n.path)).resizable().frame(width: 22, height: 22)
            Text(n.name).lineLimit(1)
            Spacer()
            GeometryReader { g in
                Capsule().fill(color.opacity(0.7))
                    .frame(width: max(2, g.size.width * CGFloat(Double(n.size) / Double(max(1, m.nodes.first?.size ?? 1)))))
            }
            .frame(width: 120, height: 5)
            Text(fmtBytes(n.size)).monospacedDigit().frame(width: 86, alignment: .trailing)
            Button { FileOps.reveal(n.path) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.plain).foregroundStyle(Theme.text2)
            Button { trashTarget = n } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(Theme.text2)
            Image(systemName: "chevron.right").foregroundStyle(n.isDir ? Theme.text2 : .clear)
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.glass))
        .contentShape(Rectangle())
        .onTapGesture { if n.isDir { m.open(n.path) } }
    }
}

// MARK: - File lớn và cũ

struct BigFile: Identifiable {
    var id: String { path }
    let path: String
    let size: Int64
    let modified: Date
    let accessed: Date
    var selected = false
}

@MainActor
final class LargeFilesModel: ObservableObject {
    static let shared = LargeFilesModel()
    @Published var files: [BigFile] = []
    @Published var loading = false
    @Published var scanned = false
    @Published var filter: Filter = .all
    @Published var message: String?

    enum Filter: String, CaseIterable { case all = "Tất cả", huge = "Trên 1 GB", old = "Lâu không mở (1 năm)"
        var title: String {
            switch self {
            case .all: String(localized: "Tất cả")
            case .huge: String(localized: "Trên 1 GB")
            case .old: String(localized: "Lâu không mở (1 năm)")
            }
        }
    }

    var shown: [BigFile] {
        switch filter {
        case .all: files
        case .huge: files.filter { $0.size >= 1_000_000_000 }
        case .old: files.filter { Date().timeIntervalSince($0.accessed) > 365 * 86_400 }
        }
    }
    var selectedSize: Int64 { files.filter(\.selected).reduce(0) { $0 + $1.size } }

    nonisolated static func find() -> [BigFile] {
        let h = NSHomeDirectory()
        // Bỏ qua ~/Library (dữ liệu app), Thùng rác, thư mục code sinh ra
        let cmd = "find \(FileOps.q(h)) -xdev \\( -path \(FileOps.q(h + "/Library")) -o -path \(FileOps.q(h + "/.Trash")) -o -name node_modules -o -name .git -o -name vendor \\) -prune -o -type f -size +100M -print0 2>/dev/null | xargs -0 stat -f '%b\t%m\t%a\t%N' 2>/dev/null"
        return Shell.run(cmd).output.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", maxSplits: 3).map(String.init)
            guard f.count == 4, let b = Int64(f[0]), let m = Double(f[1]), let a = Double(f[2]) else { return nil }
            return BigFile(path: f[3], size: b * 512, modified: Date(timeIntervalSince1970: m), accessed: Date(timeIntervalSince1970: a))
        }
        .filter { $0.size >= 100_000_000 }
        .sorted { $0.size > $1.size }
    }

    func scan() { Task { await scanAsync() } }
    func scanAsync() async {
        guard !loading else { return }
        loading = true
        files = await Task.detached(priority: .userInitiated) { LargeFilesModel.find() }.value
        loading = false; scanned = true
    }

    func trashSelected() {
        let paths = files.filter(\.selected).map(\.path)
        Task {
            let failed = await FileOps.trash(paths)
            files.removeAll { $0.selected && !failed.contains($0.path) }
            message = String(localized: "Đã chuyển \(paths.count - failed.count) file vào Thùng rác. Nhớ dọn Thùng rác để lấy lại dung lượng.")
        }
    }
}

struct LargeFilesView: View {
    @ObservedObject var m = LargeFilesModel.shared
    @State private var confirm = false

    var body: some View {
        ModulePage(title: String(localized: "File lớn và cũ"), subtitle: String(localized: "File trên 100 MB trong thư mục home, không tính dữ liệu app trong ~/Library.")) {
            if m.scanned {
                Picker("", selection: $m.filter) { ForEach(LargeFilesModel.Filter.allCases, id: \.self) { Text($0.title) } }
                    .pickerStyle(.segmented).frame(width: 360)
            }
        } content: {
            if m.loading {
                BusyView(text: String(localized: "Đang tìm file lớn. Thường mất 30 giây đến 2 phút..."))
            } else if !m.scanned {
                EmptyHint(icon: "doc.badge.ellipsis", title: String(localized: "Tìm file chiếm nhiều chỗ"),
                          detail: String(localized: "Video, file nén, ảnh đĩa, model AI đã tải... sắp xếp theo dung lượng."), action: (String(localized: "Quét"), { m.scan() }))
            } else if m.shown.isEmpty {
                EmptyHint(icon: "checkmark.seal", title: String(localized: "Không có file nào"), detail: String(localized: "Không có file khớp bộ lọc này."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(m.shown.enumerated()), id: \.element.id) { i, f in
                            let idx = m.files.firstIndex { $0.path == f.path }!
                            FileLine(path: f.path, size: f.size, note: String(localized: "Mở lần cuối \(fmtAgo(f.accessed))"), selected: $m.files[idx].selected, askAI: true)
                                .staggerIn(i)
                        }
                    }
                    .animation(Motion.spring, value: m.filter)
                    .animation(Motion.spring, value: m.files.count)
                }
                .scrollIndicators(.never)
                if let msg = m.message { Text(msg).foregroundStyle(Theme.mint) }
                SelectionBar(text: String(localized: "Đã chọn \(m.files.filter(\.selected).count) file, \(fmtBytes(m.selectedSize))"),
                             button: String(localized: "Chuyển vào Thùng rác"), danger: true, disabled: m.selectedSize == 0) { confirm = true }
            }
        }
        .alert("Chuyển \(m.files.filter(\.selected).count) file vào Thùng rác?", isPresented: $confirm) {
            Button("Chuyển vào Thùng rác", role: .destructive) { m.trashSelected() }
            Button("Huỷ", role: .cancel) {}
        } message: { Text("\(fmtBytes(m.selectedSize)). Có thể lấy lại từ Thùng rác.") }
    }
}

// MARK: - File trùng

struct DupGroup: Identifiable {
    let id = UUID()
    let size: Int64
    var files: [BigFile]     // selected = sẽ xoá; file mới nhất giữ lại
}

@MainActor
final class DupesModel: ObservableObject {
    static let shared = DupesModel()
    @Published var groups: [DupGroup] = []
    @Published var loading = false
    @Published var scanned = false
    @Published var status = ""
    @Published var message: String?

    nonisolated static let roots = ["Downloads", "Documents", "Desktop", "Pictures", "Movies", "Music"].map { "\(NSHomeDirectory())/\($0)" }

    var wasted: Int64 { groups.reduce(0) { $0 + $1.files.filter(\.selected).reduce(0) { $0 + $1.size } } }

    nonisolated static func hash(_ path: String, limit: Int?) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        var read = 0
        while true {
            let chunk = h.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            read += chunk.count
            if let limit, read >= limit { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func find(progress: @escaping @Sendable (String) -> Void) -> [DupGroup] {
        let fm = FileManager.default
        // Bỏ qua thư mục code sinh ra và dữ liệu tạm của app (profile trình duyệt, cache, log)
        let skip: Set<String> = ["node_modules", ".git", "vendor", "Library", ".venv", "venv", "build", "dist", "tmp", "temp",
                                 "cache", "Cache", "Caches", "logs", "profiles", "__pycache__", "storage", "Default"]
        var bySize: [Int64: [BigFile]] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        for root in roots {
            progress(String(localized: "Đang liệt kê \(FileOps.pretty(root))"))
            guard let en = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys,
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in en {
                guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if v.isDirectory == true { if skip.contains(url.lastPathComponent) { en.skipDescendants() }; continue }
                guard v.isRegularFile == true, let s = v.fileSize, s >= 1_000_000 else { continue }
                let d = v.contentModificationDate ?? .distantPast
                bySize[Int64(s), default: []].append(BigFile(path: url.path, size: Int64(s), modified: d, accessed: d))
            }
        }
        var groups: [DupGroup] = []
        let candidates = bySize.filter { $0.value.count > 1 }
        var done = 0
        for (size, files) in candidates {
            done += 1
            progress(String(localized: "Đang so sánh nội dung \(done)/\(candidates.count) nhóm"))
            // Lọc nhanh bằng 1 MB đầu, rồi so cả file
            var byHead: [String: [BigFile]] = [:]
            for f in files { if let h = hash(f.path, limit: 1 << 20) { byHead[h, default: []].append(f) } }
            for (_, same) in byHead where same.count > 1 {
                var byFull: [String: [BigFile]] = [:]
                if size <= 1 << 20 { byFull["x"] = same } else {
                    for f in same { if let h = hash(f.path, limit: nil) { byFull[h, default: []].append(f) } }
                }
                for (_, dup) in byFull where dup.count > 1 {
                    var sorted = dup.sorted { $0.modified > $1.modified }
                    for i in sorted.indices { sorted[i].selected = i > 0 }
                    groups.append(DupGroup(size: size, files: sorted))
                }
            }
        }
        return groups.sorted { $0.size * Int64($0.files.count - 1) > $1.size * Int64($1.files.count - 1) }
    }

    func scan() { Task { await scanAsync() } }
    func scanAsync() async {
        guard !loading else { return }
        loading = true
        groups = await Task.detached(priority: .userInitiated) {
            DupesModel.find { s in Task { @MainActor in DupesModel.shared.status = s } }
        }.value
        loading = false; scanned = true
    }

    func trashSelected() {
        // Không bao giờ xoá hết mọi bản trong một nhóm: nếu chọn hết thì giữ bản mới nhất
        for gi in groups.indices where groups[gi].files.allSatisfy(\.selected) { groups[gi].files[0].selected = false }
        let paths = groups.flatMap { $0.files.filter(\.selected).map(\.path) }
        Task {
            let failed = await FileOps.trash(paths)
            for gi in groups.indices { groups[gi].files.removeAll { $0.selected && !failed.contains($0.path) } }
            groups.removeAll { $0.files.count < 2 }
            message = String(localized: "Đã chuyển \(paths.count - failed.count) file vào Thùng rác.")
        }
    }
}

struct DupesView: View {
    @ObservedObject var m = DupesModel.shared
    @State private var confirm = false

    var body: some View {
        ModulePage(title: String(localized: "File trùng"), subtitle: String(localized: "File giống hệt nhau về nội dung trong Downloads, Documents, Desktop, Pictures, Movies, Music.")) {
            if m.scanned { Button { m.scan() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).foregroundStyle(Theme.text2) }
        } content: {
            if m.loading {
                BusyView(text: m.status.isEmpty ? String(localized: "Đang quét...") : m.status)
            } else if !m.scanned {
                EmptyHint(icon: "doc.on.doc", title: String(localized: "Tìm file bị trùng"),
                          detail: String(localized: "So sánh nội dung từng file (SHA-256), không chỉ so tên. Bản mới nhất trong mỗi nhóm được giữ lại."),
                          action: (String(localized: "Quét"), { m.scan() }))
            } else if m.groups.isEmpty {
                EmptyHint(icon: "checkmark.seal", title: String(localized: "Không có file trùng"), detail: String(localized: "Chỉ xét file từ 1 MB trở lên."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(Array($m.groups.enumerated()), id: \.element.id) { i, $g in
                            VStack(alignment: .leading, spacing: 0) {
                                Text("\(g.files.count) bản, mỗi bản \(fmtBytes(g.size))").font(.caption).foregroundStyle(Theme.text2).padding(.horizontal, 10).padding(.top, 8)
                                ForEach($g.files) { $f in
                                    FileLine(path: f.path, size: f.size, note: f.selected ? String(localized: "Xoá") : String(localized: "Giữ"), selected: $f.selected)
                                }
                            }
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.glass))
                            .staggerIn(i)
                        }
                    }
                    .animation(Motion.spring, value: m.groups.count)
                }
                .scrollIndicators(.never)
                if let msg = m.message { Text(msg).foregroundStyle(Theme.mint) }
                SelectionBar(text: String(localized: "\(m.groups.count) nhóm trùng. Xoá bản đã chọn lấy lại \(fmtBytes(m.wasted))"),
                             button: String(localized: "Chuyển vào Thùng rác"), danger: true, disabled: m.wasted == 0) { confirm = true }
            }
        }
        .alert("Chuyển các bản trùng đã chọn vào Thùng rác?", isPresented: $confirm) {
            Button("Chuyển vào Thùng rác", role: .destructive) { m.trashSelected() }
            Button("Huỷ", role: .cancel) {}
        } message: { Text("\(fmtBytes(m.wasted)). Mỗi nhóm vẫn giữ ít nhất 1 bản chưa chọn.") }
    }
}
