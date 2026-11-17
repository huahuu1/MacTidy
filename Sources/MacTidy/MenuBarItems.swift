import AppKit
import ApplicationServices
import SwiftUI

/// Một icon trên thanh menu của app khác, đọc qua Accessibility (AXExtrasMenuBar).
struct BarItem: Identifiable {
    let id: String
    let pid: pid_t
    let appName: String
    let bundlePath: String?
    let bundleID: String?
    let title: String
    let frame: CGRect            // toạ độ màn hình gốc trên-trái
    var hidden: Bool             // nằm bên trái vạch │
    var movable: Bool
}

@MainActor
final class MenuBarItemsModel: ObservableObject {
    static let shared = MenuBarItemsModel()
    @Published var items: [BarItem] = []
    @Published var loading = false
    @Published var busyID: String?
    @Published var message: String?
    @Published var trusted = AXIsProcessTrusted()

    func requestTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: - Đọc danh sách

    nonisolated static func readItems(separatorX: CGFloat?, hiddenBundles: Set<String>? = nil) -> [BarItem] {
        var out: [BarItem] = []
        let me = getpid()
        // Bỏ qua MacTidy và MenuBarAgent (nút « và icon hệ thống của macOS 27: Wi-Fi, Control Center, đồng hồ)
        for app in NSWorkspace.shared.runningApplications
        where app.processIdentifier != me && app.bundleIdentifier != "com.apple.MenuBarAgent" && app.localizedName != "MenuBarAgent" {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(ax, 0.25)      // app bị treo không làm đứng cả danh sách
            var bar: CFTypeRef?
            guard AXUIElementCopyAttributeValue(ax, "AXExtrasMenuBar" as CFString, &bar) == .success, let bar else { continue }
            var kids: CFTypeRef?
            AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids)
            for (i, el) in ((kids as? [AXUIElement]) ?? []).enumerated() {
                guard let f = frame(of: el), f.width > 0 else { continue }
                let title = string(el, kAXTitleAttribute) ?? string(el, kAXDescriptionAttribute) ?? string(el, kAXHelpAttribute) ?? ""
                let ident = string(el, "AXIdentifier") ?? ""
                let appName = app.localizedName ?? "?"
                // Đồng hồ của hệ thống không kéo được
                let movable = !(ident.lowercased().contains("clock") || title.lowercased().contains("clock"))
                let hidden = hiddenBundles.map { $0.contains(app.bundleIdentifier ?? "") }
                    ?? separatorX.map { f.midX < $0 } ?? false
                out.append(BarItem(id: "\(app.bundleIdentifier ?? appName)#\(ident.isEmpty ? String(i) : ident)",
                                   pid: app.processIdentifier, appName: appName, bundlePath: app.bundleURL?.path,
                                   bundleID: app.bundleIdentifier,
                                   title: title, frame: f, hidden: hidden, movable: movable))
            }
        }
        return out.sorted { $0.frame.minX > $1.frame.minX }      // từ phải sang trái, giống thứ tự nhìn thấy
    }

    nonisolated static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let s = v as? String, !s.isEmpty else { return nil }
        return s
    }

    nonisolated static func frame(of el: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &s) == .success else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    /// Vị trí thật của vạch │ (đọc qua Accessibility; toạ độ cửa sổ trên macOS 27 không đáng tin).
    nonisolated static func separatorFrame() -> CGRect? {
        let ax = AXUIElementCreateApplication(getpid())
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, "AXExtrasMenuBar" as CFString, &bar) == .success, let bar else { return nil }
        var kids: CFTypeRef?
        AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids)
        for el in (kids as? [AXUIElement]) ?? [] where string(el, kAXHelpAttribute) == MenuBarHider.separatorHelp {
            return frame(of: el)
        }
        return nil
    }

    /// Icon của chính MacTidy (ví dụ icon pin mới bật) mà nằm bên trái vạch │ thì bị gom mất.
    /// Kéo nó sang bên phải vạch để luôn hiện. Cần quyền Trợ năng; không có quyền thì bỏ qua.
    static func keepOwnItemsVisible() async {
        guard AXIsProcessTrusted(), MenuBarHider.shared.installed else { return }
        let hider = MenuBarHider.shared
        let wasCollapsed = hider.collapsed
        hider.holdOpen = true
        if hider.collapsed { hider.expand() }
        try? await Task.sleep(nanoseconds: 700_000_000)
        let moves: [(CGPoint, CGPoint)] = await Task.detached { () -> [(CGPoint, CGPoint)] in
            guard let sep = separatorFrame(), sep.width < 200 else { return [] }
            let ax = AXUIElementCreateApplication(getpid())
            var bar: CFTypeRef?
            guard AXUIElementCopyAttributeValue(ax, "AXExtrasMenuBar" as CFString, &bar) == .success, let bar else { return [] }
            var kids: CFTypeRef?
            AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids)
            var out: [(CGPoint, CGPoint)] = []
            for el in (kids as? [AXUIElement]) ?? [] where string(el, kAXHelpAttribute) != MenuBarHider.separatorHelp {
                guard let f = frame(of: el), f.width > 0, f.midX < sep.minX else { continue }
                out.append((CGPoint(x: f.midX, y: f.midY), CGPoint(x: sep.maxX + 3, y: f.midY)))
            }
            return out
        }.value
        for (from, to) in moves {
            await Task.detached { cmdDrag(from: from, to: to) }.value
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        hider.holdOpen = false
        if wasCollapsed || !moves.isEmpty { hider.collapse() }
    }

    func refresh() {
        trusted = AXIsProcessTrusted()
        guard trusted else { return }
        let hider = MenuBarHider.shared
        if !hider.installed { hider.enabled = true }
        hider.holdOpen = true
        if hider.collapsed { hider.expand() }
        loading = true
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)       // đợi icon hiện lại sau khi mở rộng
            let hiddenSet: Set<String>? = MenuBarHider.native ? hider.hiddenBundles : nil
            let sepX = MenuBarHider.native ? nil : await Task.detached { MenuBarItemsModel.separatorFrame()?.minX }.value
            let fresh = await Task.detached { MenuBarItemsModel.readItems(separatorX: sepX, hiddenBundles: hiddenSet) }.value
            if items.isEmpty { items = fresh } else { merge(fresh) }
            loading = false
        }
    }

    func done() { MenuBarHider.shared.holdOpen = false }

    // MARK: - Kéo icon

    /// Giả lập giữ ⌘ và kéo icon tới vị trí mới (cách macOS cho phép sắp xếp icon trên thanh menu).
    /// Con trỏ chuột được ẩn trong lúc kéo và trả về chỗ cũ sau đó.
    nonisolated static func cmdDrag(from: CGPoint, to: CGPoint) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let restore = CGEvent(source: nil)?.location
        let display = CGMainDisplayID()
        CGDisplayHideCursor(display)
        defer {
            if let r = restore { CGWarpMouseCursorPosition(r) }
            CGDisplayShowCursor(display)
        }
        func post(_ type: CGEventType, _ p: CGPoint) {
            guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { return }
            e.flags = .maskCommand
            e.post(tap: .cghidEventTap)
        }
        post(.mouseMoved, from); usleep(30_000)
        post(.leftMouseDown, from); usleep(70_000)
        let steps = 8
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            post(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y))
            usleep(12_000)
        }
        usleep(60_000)
        post(.leftMouseUp, to)
        usleep(40_000)
    }

    /// Cập nhật vị trí và trạng thái gom nhưng giữ nguyên thứ tự trong danh sách (không làm các dòng nhảy chỗ).
    private func merge(_ fresh: [BarItem]) {
        var byID = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [BarItem] = []
        for old in items {
            if let n = byID.removeValue(forKey: old.id) { out.append(n) }
        }
        out.append(contentsOf: fresh.filter { byID[$0.id] != nil })   // icon mới xuất hiện: thêm cuối danh sách
        items = out
    }

    /// Hàng đợi: bấm nhiều công tắc liền nhau thì kéo lần lượt từng icon.
    private var queue: [(BarItem, Bool)] = []

    func setHidden(_ item: BarItem, _ hide: Bool) {
        if MenuBarHider.native, let id = item.bundleID {
            // macOS 27: chỉ cần thêm/bỏ app khỏi danh sách gom, macOS tự ẩn. Không kéo chuột.
            for i in items.indices where items[i].bundleID == id { items[i].hidden = hide }
            MenuBarHider.shared.setHidden(bundle: id, hide)
            return
        }
        guard trusted, item.movable else { return }
        // Đổi công tắc ngay để thấy phản hồi, việc kéo chạy phía sau
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].hidden = hide }
        queue.append((item, hide))
        if busyID == nil { runQueue() }
    }

    private func runQueue() {
        guard !queue.isEmpty else { busyID = nil; return }
        let (item, hide) = queue.removeFirst()
        let hider = MenuBarHider.shared
        if hider.collapsed { hider.expand() }
        busyID = item.id
        message = nil
        Task {
            // Đọc lại vị trí mới nhất của icon và vạch │ ngay trước khi kéo
            let sepX = await Task.detached { MenuBarItemsModel.separatorFrame() }.value
            let fresh = await Task.detached { MenuBarItemsModel.readItems(separatorX: sepX?.minX) }.value
            guard let sep = sepX, sep.width < 200, let cur = fresh.first(where: { $0.id == item.id }) else {
                message = String(localized: "Chưa đọc được vị trí vạch │ hoặc icon. Bấm Làm mới rồi thử lại.")
                merge(fresh)
                busyID = nil; queue.removeAll()
                return
            }
            if cur.hidden != hide {
                let from = CGPoint(x: cur.frame.midX, y: cur.frame.midY)
                // Gom: thả ngay bên trái vạch │. Bỏ gom: thả ngay bên phải vạch │.
                let to = hide ? CGPoint(x: sep.minX - 3, y: from.y) : CGPoint(x: sep.maxX + 3, y: from.y)
                await Task.detached { MenuBarItemsModel.cmdDrag(from: from, to: to) }.value
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            let after = await Task.detached { () -> [BarItem] in
                let x = MenuBarItemsModel.separatorFrame()?.minX
                return MenuBarItemsModel.readItems(separatorX: x)
            }.value
            merge(after)
            if let now = items.first(where: { $0.id == item.id }), now.hidden != hide {
                message = String(localized: "Chưa kéo được \(item.appName). Thử lại, hoặc tự giữ ⌘ và kéo icon đó qua vạch │.")
            }
            runQueue()
        }
    }
}

// MARK: - Giao diện

struct MenuBarItemsView: View {
    @ObservedObject var m = MenuBarItemsModel.shared
    @ObservedObject var hider = MenuBarHider.shared

    var body: some View {
        ModulePage(title: String(localized: "Gom icon thanh menu"), subtitle: MenuBarHider.native
            ? String(localized: "Bật Gom ở app nào thì icon của app đó ẩn hẳn khỏi thanh menu. Bấm nút ‹ để hiện lại tạm thời.")
            : MenuBarHider.systemOverflow
            ? String(localized: "Chọn icon nào được gom. Icon đã gom nằm trong nút « của macOS ở thanh menu.")
            : String(localized: "Chọn icon nào được gom. Icon đã gom nằm bên trái vạch │ và chỉ hiện khi bấm nút ‹.")) {
            HStack(spacing: 8) {
                Button { m.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).foregroundStyle(Theme.text2)
                PillButton(title: hider.collapsed ? String(localized: "Hiện icon đã gom") : String(localized: "Gom lại ngay"), tint: nil) {
                    m.done(); hider.toggle()
                }
                .disabled(!hider.installed)
            }
        } content: {
            if !m.trusted {
                EmptyHint(icon: "hand.raised.square",
                          title: String(localized: "Cần quyền Trợ năng (Accessibility)"),
                          detail: String(localized: "MacTidy cần quyền này để đọc danh sách icon trên thanh menu và kéo icon giúp bạn. Bấm nút dưới, bật MacTidy trong Cài đặt hệ thống, rồi quay lại bấm Làm mới."),
                          action: (String(localized: "Cấp quyền"), { m.requestTrust() }))
            } else if m.loading && m.items.isEmpty {
                BusyView(text: String(localized: "Đang đọc icon trên thanh menu..."))
            } else {
                if let msg = m.message { Text(msg).foregroundStyle(Color(hex: 0xF2B544)) }
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(m.items.enumerated()), id: \.element.id) { i, it in
                            row(it).staggerIn(i)
                        }
                    }
                }
                .scrollIndicators(.never)
                SelectionBar(text: String(localized: "\(m.items.filter(\.hidden).count) icon đang được gom. macOS tự nhớ vị trí, kể cả sau khi restart."),
                             button: String(localized: "Xong")) {
                    m.done(); if !hider.collapsed { hider.collapse() }
                }
            }
        }
        .onAppear { m.refresh() }
        .onDisappear { m.done() }
        .task {
            // Chờ người dùng cấp quyền trong Cài đặt hệ thống, có quyền là tự tải danh sách
            while !m.trusted && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if AXIsProcessTrusted() { m.refresh() }
            }
        }
    }

    private func row(_ it: BarItem) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: IconCache.shared.icon(for: it.bundlePath)).resizable().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(it.appName).font(.body.weight(.medium))
                if !it.title.isEmpty && it.title != it.appName {
                    Text(it.title).font(.caption).foregroundStyle(Theme.text2).lineLimit(1)
                }
            }
            Spacer()
            if m.busyID == it.id { ProgressView().controlSize(.small) }
            Text(it.hidden ? "Đang gom" : "Đang hiện").font(.caption).foregroundStyle(it.hidden ? Theme.mint : Theme.text2)
            Toggle("", isOn: Binding(get: { it.hidden }, set: { m.setHidden(it, $0) }))
                .labelsHidden().toggleStyle(.switch).tint(Theme.mint)
                .disabled(!it.movable)
                .help(it.movable ? "Bật để gom icon này" : "macOS không cho di chuyển icon này")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.glass))
        .animation(Motion.spring, value: it.hidden)
    }
}
