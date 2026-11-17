import AppKit
import SwiftUI

/// Chế độ kiểm tra: chụp từng màn hình ra PNG rồi thoát. Bật bằng MACTIDY_SNAPSHOT=<thư mục>.
/// MACTIDY_PAGES=smart,clean,... để chỉ chụp một số trang.
@MainActor
enum Snapshot {
    static func run(dir: String) async {
        func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        func waitWhile(_ busy: () -> Bool, max: Double = 240) async {
            var t = 0.0
            while busy() && t < max { await wait(1); t += 1 }
        }
        func shot(_ name: String) {
            if let w = NSApp.windows.first(where: { $0.title == "MacTidy" && $0.isVisible }), let v = w.contentView {
                save(v, to: "\(dir)/\(name).png")
            }
        }
        let only = ProcessInfo.processInfo.environment["MACTIDY_PAGES"]?.split(separator: ",").map(String.init)
        func want(_ p: String) -> Bool { only == nil || only!.contains(p) }

        await wait(5)
        if want("smart") {
            Nav.shared.page = .smart; await wait(1); shot("smart-idle")
            SmartScanModel.shared.scan(); await wait(3); shot("smart-scanning")
            await waitWhile { SmartScanModel.shared.phase == .scanning }
            await wait(1); shot("smart-results")
        }
        if want("overview") { Nav.shared.page = .overview; await wait(12); shot("overview") }
        if want("memory") { Nav.shared.page = .memory; await wait(6); shot("memory") }
        if want("cpu") { Nav.shared.page = .cpu; await wait(8); shot("cpu") }
        if want("clean") { Nav.shared.page = .clean; await wait(2); shot("clean") }
        if want("privacy") { Nav.shared.page = .privacy; await waitWhile { PrivacyModel.shared.loading || !PrivacyModel.shared.loaded }; await wait(1); shot("privacy") }
        if want("maintenance") { Nav.shared.page = .maintenance; await wait(1.5); shot("maintenance") }
        if want("startup") { Nav.shared.page = .startup; await wait(1); await waitWhile { StartupModel.shared.loading }; await wait(1); shot("startup") }
        if want("uninstall") {
            Nav.shared.page = .uninstall; await wait(1); await waitWhile { AppsModel.shared.loading }
            await wait(8)
            if let a = AppsModel.shared.sorted.first { AppsModel.shared.select(a) }
            await waitWhile { AppsModel.shared.findingLeftovers }; await wait(1); shot("uninstall")
        }
        if want("update") { Nav.shared.page = .update; await wait(1); await waitWhile { UpdaterModel.shared.loading }; await wait(1); shot("update") }
        if want("space") { Nav.shared.page = .space; await wait(1); await waitWhile { SpaceModel.shared.loading }; await wait(1); shot("space") }
        if want("large") {
            Nav.shared.page = .large
            if !LargeFilesModel.shared.scanned { LargeFilesModel.shared.scan() }
            await wait(1); await waitWhile { LargeFilesModel.shared.loading }; await wait(1); shot("large")
        }
        if want("dupes") {
            Nav.shared.page = .dupes; DupesModel.shared.scan()
            await wait(1); await waitWhile { DupesModel.shared.loading }; await wait(1); shot("dupes")
        }
        if want("ai") {
            Nav.shared.page = .clean
            await Cleaner.shared.scanAsync()
            if let uv = Cleaner.shared.items.first(where: { $0.id == "uv" }) {
                AIAdvisor.shared.ask(key: "clean-uv", title: uv.name, paths: uv.paths, action: "chạy lệnh: " + uv.cleanCmd, size: uv.size)
                await wait(1)
                while case .running = AIAdvisor.shared.states["clean-uv"] { await wait(1) }
                await wait(1.5)
                if case .done(let v, let c) = AIAdvisor.shared.states["clean-uv"] {
                    try? "\(v.verdict)\n\(c)\n\(v.summary)\n\(v.evidence.joined(separator: "\n"))".write(toFile: "\(dir)/ai.txt", atomically: true, encoding: .utf8)
                } else if case .failed(let m) = AIAdvisor.shared.states["clean-uv"] {
                    try? "FAILED: \(m)".write(toFile: "\(dir)/ai.txt", atomically: true, encoding: .utf8)
                }
                shot("ai")
            }
        }
        if want("strip") {
            await wait(7)   // đợi vài lần đo để có nhiệt độ và tốc độ mạng
            let L = LiveCPU.shared
            let cases: [(String, Double, Bool)] = [("strip", L.cpu, false), ("strip-100", 100, false), ("strip-net", L.cpu, true)]
            for (name, cpu, net) in cases {
                let img = StripRenderer.image(cpu: cpu, mem: L.memPercent, cpuTemp: L.cpuTemp, gpuTemp: L.gpuTemp,
                                              netIn: L.netIn, netOut: L.netOut, hot: name == "strip-100",
                                              showTemp: true, showCPU: true, showRAM: true, showNet: net,
                                              battery: L.battery, showBattery: true)
                // Giả lập thanh menu tối: nền tối, ảnh template tô trắng, vẽ ở 4x
                let scale: CGFloat = 4, pad: CGFloat = 6
                let size = NSSize(width: img.size.width + pad * 2, height: img.size.height + pad * 2)
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
                rep.size = size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                NSColor(white: 0.12, alpha: 1).setFill(); NSRect(origin: .zero, size: size).fill()
                let tinted = NSImage(size: img.size, flipped: false) { r in
                    img.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true
                }
                tinted.draw(in: NSRect(x: pad, y: pad, width: img.size.width, height: img.size.height))
                NSGraphicsContext.restoreGraphicsState()
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            }
        }
        if want("done") {
            // Màn hình dọn xong (không xoá gì thật)
            let host = NSHostingView(rootView: VStack(spacing: 22) { DoneBadge(); DoneTitle(freed: 12_345_678_901) }
                .frame(width: 600, height: 420).foregroundStyle(.white)
                .background(ThermalBackground(state: .nominal)))
            let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 600, height: 420),
                               styleMask: [.borderless], backing: .buffered, defer: false)
            win.contentView = host
            win.orderFront(nil)
            await wait(0.35); save(host, to: "\(dir)/done-mid.png")
            await wait(2); save(host, to: "\(dir)/done-end.png")
            win.orderOut(nil)
        }
        if want("battery") {
            await wait(7)
            let host = NSHostingView(rootView: BatteryView().environmentObject(SystemMonitor.shared))
            let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 800),
                               styleMask: [.borderless], backing: .buffered, defer: false)
            win.contentView = host
            host.frame.size = host.fittingSize
            win.setContentSize(host.fittingSize)
            win.orderFront(nil)
            await wait(1.5)
            save(host, to: "\(dir)/battery.png")
            win.orderOut(nil)
        }
        if want("menubar") {
            let host = NSHostingView(rootView: MenuBarView()
                .environmentObject(SystemMonitor.shared)
                .environmentObject(Nav.shared)
                .environmentObject(Cleaner.shared))
            let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 370, height: 600),
                               styleMask: [.borderless], backing: .buffered, defer: false)
            win.contentView = host
            host.frame.size = host.fittingSize
            win.setContentSize(host.fittingSize)
            win.orderFront(nil)
            await wait(1.5)
            save(host, to: "\(dir)/menubar.png")
        }
        NSApp.terminate(nil)
    }

    static func save(_ view: NSView, to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
