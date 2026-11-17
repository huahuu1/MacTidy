import AppKit
import ApplicationServices
import MBShim
import SwiftUI

/// Gom icon trên thanh menu.
///
/// Thanh menu sẽ có thứ tự: [icon bị ẩn ...] │ ‹ [MacTidy] [icon của hệ thống]
/// - Người dùng giữ ⌘ và kéo icon muốn ẩn sang bên TRÁI vạch │.
/// - Thu gọn: vạch │ giãn ra 10.000 điểm, đẩy mọi icon bên trái nó ra ngoài màn hình.
/// - Mở rộng: vạch │ co lại về 8 điểm, các icon hiện lại.
/// macOS tự nhớ vị trí các icon nhờ autosaveName.
@MainActor
final class MenuBarHider: NSObject, ObservableObject {
    static let shared = MenuBarHider()

    enum Keys {
        static let enabled = "hider.enabled"
        static let autoHide = "hider.autoHide"
        static let autoHideDelay = "hider.autoHideDelay"
    }

    @Published private(set) var collapsed = false
    @Published private(set) var installed = false
    /// Lý do không thu gọn được (để hiện cho người dùng), nil nếu bình thường.
    @Published private(set) var problem: String?
    /// Đang sắp xếp icon trong trang Thanh menu: không tự thu gọn
    var holdOpen = false

    // MARK: Cách gom native (macOS 27): MenuBarClientCore ẩn icon theo danh sách app được phép, không để khoảng trống

    /// Có dùng được cách gom native không (macOS 27 có MenuBarClientCore)
    nonisolated static let native: Bool = MBShimIsAvailable()
    private var assertion: AnyObject?
    private var activationID = 0

    /// Bundle id của các app được gom (người dùng chọn trong trang Gom icon)
    var hiddenBundles: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "hider.hiddenBundles") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "hider.hiddenBundles") }
    }
    /// Bundle id của các app từng có icon trên thanh menu (đọc lúc đang hiện hết), để biết app nào được phép hiện
    var knownBundles: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "hider.knownBundles") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "hider.knownBundles") }
    }

    /// Đọc qua Accessibility các app đang có icon trên thanh menu (chỉ đúng khi đang hiện hết).
    nonisolated static func menuBarBundles() -> Set<String> {
        var out: Set<String> = []
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier else { continue }
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(ax, 0.25)
            var bar: CFTypeRef?
            if AXUIElementCopyAttributeValue(ax, "AXExtrasMenuBar" as CFString, &bar) == .success, bar != nil { out.insert(id) }
        }
        return out
    }

    /// Bật giới hạn: chỉ hiện icon hệ thống, MacTidy và các app không bị gom.
    /// Bật giới hạn mới xong mới bỏ giới hạn cũ, để thanh menu không chớp.
    private func nativeActivate(completion: ((Bool) -> Void)? = nil) {
        activationID += 1
        let myID = activationID
        var allowed = knownBundles.subtracting(hiddenBundles)
        if let me = Bundle.main.bundleIdentifier { allowed.insert(me) }
        allowed.insert("com.apple.MenuBarAgent")
        let system = (0..<64).map { NSNumber(value: $0) }
        MBShimActivate(system, Array(allowed).sorted()) { [weak self] newAssertion, error in
            guard let self else { MBShimInvalidate(newAssertion); return }
            guard myID == self.activationID, let newAssertion else {
                MBShimInvalidate(newAssertion)
                if let error { self.problem = String(localized: "macOS từ chối gom icon: \(error.localizedDescription)") }
                completion?(false)
                return
            }
            let old = self.assertion
            self.assertion = newAssertion as AnyObject
            MBShimInvalidate(old)
            self.problem = nil
            completion?(true)
        }
    }

    private func nativeRelease() {
        activationID += 1
        MBShimInvalidate(assertion)
        assertion = nil
    }

    /// Đổi danh sách gom (từ trang Gom icon): nếu đang gom thì áp dụng ngay
    func setHidden(bundle: String, _ hide: Bool) {
        var h = hiddenBundles
        if hide { h.insert(bundle) } else { h.remove(bundle) }
        hiddenBundles = h
        if collapsed && Self.native { nativeActivate() }
    }

    /// Khung của vạch │ và nút ‹ theo toạ độ màn hình gốc trên-trái (giống CGEvent và Accessibility).
    func cgFrames() -> (separator: CGRect, toggle: CGRect)? {
        guard ensureOrder(), let s = separatorItem?.button?.window?.frame, let t = toggleItem?.button?.window?.frame else { return nil }
        let H = NSScreen.screens.first?.frame.height ?? 0
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height) }
        return (flip(s), flip(t))
    }

    private var toggleItem: NSStatusItem?
    private var separatorItem: NSStatusItem?
    private var rehideTimer: Timer?
    private var refitTimer: Timer?
    private let hiddenLength: CGFloat = 10_000
    private let separatorLength: CGFloat = 10

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.enabled) }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.enabled)
            newValue ? install() : uninstall()
        }
    }
    var autoHide: Bool {
        get { UserDefaults.standard.object(forKey: Keys.autoHide) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Keys.autoHide) }
    }
    var autoHideDelay: TimeInterval {
        get { let v = UserDefaults.standard.double(forKey: Keys.autoHideDelay); return v > 0 ? v : 10 }
        set { UserDefaults.standard.set(newValue, forKey: Keys.autoHideDelay) }
    }

    /// Gọi khi app mở: đợi icon MacTidy xuất hiện trước, để nút ‹ nằm bên trái nó.
    func start() {
        guard enabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.install() }
    }

    // MARK: - Cài / gỡ

    /// macOS 26 trở lên có sẵn nút « của hệ thống chứa các icon không đủ chỗ.
    /// Khi đó chỉ cần vạch │: icon bên trái vạch được macOS đưa vào «. Không cần nút ‹ riêng.
    nonisolated static var systemOverflow: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 }

    func install() {
        guard toggleItem == nil, separatorItem == nil else { return }
        if Self.native {
            let tog = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            tog.autosaveName = "MacTidyHiderToggleNative"
            tog.behavior = []
            tog.button?.target = self
            tog.button?.action = #selector(toggleClicked(_:))
            tog.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            tog.button?.toolTip = String(localized: "Bấm để hiện/ẩn icon đã gom. Chuột phải để xem tuỳ chọn.")
            toggleItem = tog
            installed = true
            collapsed = false
            updateToggleIcon()
            // Ghi nhận các app đang có icon (lúc chưa gom gì), rồi gom
            Task {
                let found = await Task.detached { MenuBarHider.menuBarBundles() }.value
                knownBundles = knownBundles.union(found)
                scheduleRehide(after: 3)
            }
            // App mới mở trong lúc đang gom: thêm vào danh sách được phép (nếu không bị chọn gom)
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
                guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, let id = app.bundleIdentifier else { return }
                Task { @MainActor in
                    guard let self, self.installed else { return }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if !self.knownBundles.contains(id) {
                        self.knownBundles.insert(id)
                        if self.collapsed { self.nativeActivate() }
                    }
                }
            }
            return
        }
        let sep = NSStatusBar.system.statusItem(withLength: separatorLength)
        sep.autosaveName = "MacTidyHiderSeparator"
        sep.behavior = []                     // không cho kéo ra khỏi thanh menu để xoá nhầm
        if let b = sep.button {
            b.image = Self.separatorImage()
            b.toolTip = Self.separatorHelp
            b.target = self
            b.action = #selector(toggleClicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        separatorItem = sep
        if !Self.systemOverflow {
            // macOS cũ: cần nút ‹ để mở lại. Tạo sau vạch; ensureOrder() sẽ đổi vai trò nếu macOS đặt ngược.
            let tog = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            tog.autosaveName = "MacTidyHiderToggle"
            tog.behavior = []
            tog.button?.target = self
            tog.button?.action = #selector(toggleClicked(_:))
            tog.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            tog.button?.toolTip = String(localized: "Bấm để hiện/ẩn icon. Chuột phải để xem tuỳ chọn.")
            toggleItem = tog
        }
        installed = true
        collapsed = false
        updateToggleIcon()
        // Để người dùng thấy vạch │ một lúc rồi mới thu gọn
        scheduleRehide(after: 4)
    }

    nonisolated static let separatorHelp = String(localized: "MacTidy: icon bên trái vạch này được gom. Giữ ⌘ và kéo icon qua vạch để gom hoặc bỏ gom.")

    func uninstall() {
        nativeRelease()
        rehideTimer?.invalidate()
        refitTimer?.invalidate()
        if let s = separatorItem { NSStatusBar.system.removeStatusItem(s) }
        if let t = toggleItem { NSStatusBar.system.removeStatusItem(t) }
        separatorItem = nil
        toggleItem = nil
        installed = false
        collapsed = false
        problem = nil
    }

    // MARK: - Thu gọn / mở rộng

    func toggle() {
        if Self.native {
            // Dựa vào việc đang giữ lệnh gom hay không, không dựa vào cờ (cờ có thể lệch nếu macOS từ chối)
            Self.log("bấm nút: \(assertion == nil ? "gom" : "hiện")")
            assertion == nil ? collapse() : expand()
        } else {
            collapsed ? expand() : collapse()
        }
    }

    /// Ghi nhật ký gom/hiện vào ~/Library/Logs/MacTidy.log để tìm lỗi khi người dùng báo.
    static func log(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/MacTidy.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Vạch │ phải nằm bên trái nút ‹, nếu không sẽ đẩy luôn nút ‹ ra ngoài và không bấm lại được.
    /// Nếu đang ngược (macOS vừa đặt icon, hoặc người dùng kéo đổi chỗ) thì đổi vai trò 2 icon cho nhau.
    func ensureOrder() -> Bool {
        if toggleItem == nil { return separatorItem != nil }      // chỉ có vạch │: không có gì để đổi
        guard let s = separatorItem, let t = toggleItem,
              let sx = s.button?.window?.frame.minX, let tx = t.button?.window?.frame.minX, sx > 0, tx > 0 else { return false }
        if sx > tx {
            separatorItem = t
            toggleItem = s
            t.length = separatorLength
            t.button?.image = Self.separatorImage()
            t.button?.toolTip = Self.separatorHelp
            s.length = NSStatusItem.squareLength
            s.button?.toolTip = String(localized: "Bấm để hiện/ẩn icon. Chuột phải để xem tuỳ chọn.")
            updateToggleIcon()
        }
        return true
    }

    func collapse() {
        if Self.native {
            guard toggleItem != nil, assertion == nil else { return }
            rehideTimer?.invalidate()
            // Đổi nút ngay để thấy phản hồi; nếu macOS từ chối thì trả lại
            collapsed = true
            updateToggleIcon()
            // Gom ngay theo danh sách đã biết; quét lại sau, có app mới thì cập nhật (không làm chậm nút bấm)
            Task {
                let found = await Task.detached { MenuBarHider.menuBarBundles() }.value
                let added = found.subtracting(knownBundles)
                if !added.isEmpty {
                    knownBundles = knownBundles.union(found)
                    if assertion != nil { nativeActivate() }
                }
            }
            do {
                nativeActivate { [weak self] ok in
                    guard let self else { return }
                    Self.log("gom: \(ok ? "được" : "macOS từ chối, thử lại") \(self.problem ?? "")")
                    if ok { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.nativeActivate { ok2 in
                            Self.log("gom lần 2: \(ok2 ? "được" : "vẫn lỗi") \(self.problem ?? "")")
                            if !ok2 { self.collapsed = false; self.updateToggleIcon() }
                        }
                    }
                }
            }
            return
        }
        guard separatorItem != nil else { return }
        guard ensureOrder(), let s = separatorItem else {
            // Chưa đọc được vị trí: thử lại sau
            scheduleRehide(after: 1)
            return
        }
        problem = nil
        rehideTimer?.invalidate()
        let len = min(collapsedLength(for: s), maxFit ?? .greatestFiniteMagnitude)
        s.length = len
        s.button?.image = nil   // macOS 26+ đã có nút « của hệ thống, không vẽ thêm nút riêng
        collapsed = true
        updateToggleIcon()
        // macOS 26+: theo dõi để vạch │ không bị chính macOS cất vào «, và tính lại khi có app mới thêm icon
        if Self.systemOverflow {
            refitTimer?.invalidate()
            refitTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refit() }
            }
        }
    }

    private func refit() {
        guard collapsed, let s = separatorItem, AXIsProcessTrusted() else { return }
        if let f = MenuBarItemsModel.separatorFrame() {
            // Vạch đang hiện: chỉnh lại nếu chỗ trống đổi, nhưng không vượt độ rộng từng bị macOS cất vào «
            let target = min(targetLength(rightEdge: f.maxX), maxFit ?? .greatestFiniteMagnitude)
            if abs(target - s.length) > 6 { s.length = target }
        } else {
            // Vạch bị macOS cất vào «: nhớ giới hạn này và thu hẹp dần cho tới khi vạch hiện lại
            let smaller = max(separatorLength, s.length - 24)
            maxFit = smaller
            s.length = smaller
        }
    }

    /// Độ rộng lớn nhất của vạch mà macOS chưa cất vào « (học được khi chạy)
    private var maxFit: CGFloat?

    /// Chừa chỗ cho nút « của macOS (khoảng 20 điểm) cộng khoảng đệm.
    private let overflowRoom: CGFloat = 40

    private func targetLength(rightEdge: CGFloat) -> CGFloat {
        let screen = NSScreen.screens.first
        let leftLimit: CGFloat
        if let aux = screen?.auxiliaryTopRightArea, aux.width > 0 {
            leftLimit = aux.minX                                  // máy có tai thỏ: icon chỉ nằm bên phải tai thỏ
        } else {
            leftLimit = (screen?.frame.width ?? 1512) * 0.5       // không có tai thỏ: chừa nửa trái cho menu của app
        }
        return max(separatorLength, rightEdge - leftLimit - overflowRoom)
    }

    /// Độ rộng của vạch │ khi gom.
    /// macOS cũ: rất rộng (10.000) để đẩy icon bên trái ra khỏi màn hình.
    /// macOS 26+: icon quá rộng bị chính macOS cất vào «, nên vạch chỉ rộng vừa phần chỗ trống
    /// (chừa chỗ cho nút «); macOS phải cất các icon bên trái vạch vào « để đủ chỗ.
    private func collapsedLength(for s: NSStatusItem) -> CGFloat {
        guard Self.systemOverflow else { return hiddenLength }
        let right: CGFloat = MenuBarItemsModel.separatorFrame().map { $0.maxX }
            ?? s.button?.window?.frame.maxX ?? (NSScreen.screens.first?.frame.width ?? 1512) * 0.6
        return targetLength(rightEdge: right)
    }

    /// Khi gom: vạch rộng nhưng trống, chỉ vẽ nút ‹ ở mép phải. Bấm vào để hiện lại icon ngay tại chỗ.
    private static func collapsedImage(width: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: max(10, width), height: 18), flipped: false) { r in
            let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            if let c = NSImage(systemSymbolName: "chevron.compact.left", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                c.draw(in: NSRect(x: r.maxX - c.size.width - 1, y: (r.height - c.size.height) / 2, width: c.size.width, height: c.size.height))
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    func expand() {
        if Self.native {
            Self.log("hiện icon")
            nativeRelease()
            collapsed = false
            updateToggleIcon()
            if autoHide { scheduleRehide(after: autoHideDelay) }
            return
        }
        refitTimer?.invalidate()
        guard let s = separatorItem else { return }
        s.length = separatorLength
        s.button?.image = Self.separatorImage()
        collapsed = false
        updateToggleIcon()
        if autoHide { scheduleRehide(after: autoHideDelay) }
    }

    private func scheduleRehide(after seconds: TimeInterval) {
        rehideTimer?.invalidate()
        rehideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.collapsed else { return }
                if self.holdOpen { self.scheduleRehide(after: 3); return }
                // Đang giữ ⌘ (có thể đang kéo icon) hoặc đang mở menu của icon khác: đợi thêm
                if NSEvent.modifierFlags.contains(.command) || NSEvent.pressedMouseButtons != 0 {
                    self.scheduleRehide(after: 3)
                } else {
                    self.collapse()
                }
            }
        }
    }

    private func updateToggleIcon() {
        guard let b = toggleItem?.button else { return }
        let name = collapsed ? "chevron.compact.left" : "chevron.compact.right"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: collapsed ? String(localized: "Hiện icon đã ẩn") : String(localized: "Ẩn icon"))
        img?.isTemplate = true
        b.image = img?.withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
    }

    private static func separatorImage() -> NSImage {
        let img = NSImage(size: NSSize(width: 4, height: 16), flipped: false) { r in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 1.25, y: 1, width: 1.5, height: r.height - 2), xRadius: 0.75, yRadius: 0.75).fill()
            return true
        }
        img.isTemplate = true
        return img
    }

    // MARK: - Bấm chuột

    @objc private func toggleClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            showMenu(from: sender)
        } else if collapsed && Self.systemOverflow && !Self.native {
            // Đang gom trên macOS 26+: vạch là khoảng trống, bấm nhầm vào thì không làm gì (dùng nút « của macOS)
            return
        } else {
            toggle()
        }
    }

    private func showMenu(from button: NSStatusBarButton) {
        let m = NSMenu()
        m.addItem(withTitle: collapsed ? String(localized: "Hiện icon đã ẩn") : String(localized: "Ẩn icon"), action: #selector(menuToggle), keyEquivalent: "").target = self
        m.addItem(.separator())
        let auto = m.addItem(withTitle: String(localized: "Tự ẩn lại sau \(Int(autoHideDelay)) giây"), action: #selector(menuAutoHide), keyEquivalent: "")
        auto.target = self
        auto.state = autoHide ? .on : .off
        let hint = m.addItem(withTitle: String(localized: "Cách dùng: giữ ⌘ và kéo icon sang trái vạch │"), action: nil, keyEquivalent: "")
        hint.isEnabled = false
        m.addItem(.separator())
        m.addItem(withTitle: String(localized: "Tắt gom menu bar"), action: #selector(menuDisable), keyEquivalent: "").target = self
        // Mở menu trực tiếp. Không dùng cách gán menu + performClick: trên macOS 27 performClick
        // gửi lại sự kiện bấm về hàm này, gây đệ quy vô hạn và crash.
        m.popUp(positioning: m.items.first, at: NSEvent.mouseLocation, in: nil)   // mở ngay tại con trỏ (toạ độ màn hình)
    }

    /// Kiểm tra: ghi vị trí các icon của MacTidy (dùng khi MACTIDY_HIDER_TEST=<file>).
    func debugFrames() -> String {
        func f(_ w: NSWindow?) -> String { w.map { "x=\(Int($0.frame.minX)) w=\(Int($0.frame.width))" } ?? "không có" }
        var out = "vạch │: \(f(separatorItem?.button?.window)) length=\(Int(separatorItem?.length ?? -1))\n"
        out += "nút ‹: \(f(toggleItem?.button?.window))\n"
        for w in NSApp.windows where String(describing: type(of: w)).contains("StatusBar") {
            out += "status window: \(f(w))\n"
        }
        out += "collapsed=\(collapsed) problem=\(problem ?? "-")\n"
        return out
    }

    @objc private func menuToggle() { toggle() }
    @objc private func menuAutoHide() { autoHide.toggle(); if autoHide && !collapsed { scheduleRehide(after: autoHideDelay) } }
    @objc private func menuDisable() { enabled = false }
}

/// Phần cài đặt trong popup menu bar.
struct HiderSettingsView: View {
    var onChoose: () -> Void = {}
    @ObservedObject var hider = MenuBarHider.shared
    @State private var enabled = MenuBarHider.shared.enabled
    @State private var autoHide = MenuBarHider.shared.autoHide

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Gom icon trên thanh menu", systemImage: "menubar.rectangle").font(.subheadline.weight(.semibold))
                Spacer()
                Toggle("", isOn: Binding(get: { enabled }, set: { enabled = $0; hider.enabled = $0 }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(Theme.mint)
            }
            if enabled {
                HStack {
                    Text(MenuBarHider.native ? "Bấm nút ‹ trên thanh menu để hiện icon đã gom." : (MenuBarHider.systemOverflow ? "Icon đã gom nằm trong nút « của macOS." : "Bấm nút ‹ › để hiện hoặc ẩn icon đã gom."))
                        .font(.caption).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Chọn icon cần gom…", action: onChoose)
                        .buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(Theme.mint)
                }
                HStack {
                    Toggle("Tự ẩn lại sau \(Int(hider.autoHideDelay)) giây", isOn: Binding(get: { autoHide }, set: { autoHide = $0; hider.autoHide = $0 }))
                        .toggleStyle(.checkbox).font(.caption)
                    Spacer()
                    Button(hider.collapsed ? "Hiện icon" : "Ẩn icon") { hider.toggle() }
                        .buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(Theme.mint)
                }
                if let p = hider.problem {
                    Text(p).font(.caption).foregroundStyle(Color(hex: 0xF2B544)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.glass))
        .animation(Motion.spring, value: enabled)
    }
}
