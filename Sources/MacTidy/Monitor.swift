import AppKit
import Darwin
import IOKit.ps
import Foundation

struct AppUsage: Identifiable, Hashable {
    let id: String          // đường dẫn .app hoặc "proc:<tên>"
    let name: String
    let bundlePath: String?
    var cpu: Double
    var memBytes: UInt64
    var pids: [Int32]
    var quittable = false
}

enum ProcSampler {
    /// Lấy tất cả process, gộp theo .app ngoài cùng.
    static func sample() -> [AppUsage] {
        let out = runPS()
        let me = getpid()
        var groups: [String: AppUsage] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]), let cpu = Double(parts[1]),
                  let rss = UInt64(parts[2]), pid != me else { continue }
            let path = String(parts[3]).trimmingCharacters(in: .whitespaces)
            let name0 = (path as NSString).lastPathComponent
            if name0 == "ps" { continue }
            let mem = footprint(pid) ?? rss * 1024
            let key: String, name: String, bundle: String?
            if let r = path.range(of: ".app/") {
                let b = String(path[..<r.lowerBound]) + ".app"
                key = b; bundle = b
                name = ((b as NSString).lastPathComponent as NSString).deletingPathExtension
            } else {
                key = "proc:" + name0; bundle = nil; name = name0
            }
            if var g = groups[key] {
                g.cpu += cpu; g.memBytes += mem; g.pids.append(pid); groups[key] = g
            } else {
                groups[key] = AppUsage(id: key, name: name, bundlePath: bundle, cpu: cpu, memBytes: mem, pids: [pid])
            }
        }
        return Array(groups.values)
    }

    /// Gọi thẳng /bin/ps, không qua shell.
    static func runPS() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,pcpu=,rss=,comm="]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// RAM thật (giống Activity Monitor). Chỉ đọc được process của user hiện tại.
    static func footprint(_ pid: Int32) -> UInt64? {
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return r == 0 ? info.ri_phys_footprint : nil
    }
}

@MainActor
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    @Published var cpu: Double = 0
    @Published var cpuHistory: [Double] = []
    @Published var memUsed: UInt64 = 0
    let memTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    @Published var swapUsed: UInt64 = 0
    @Published var diskFree: Int64 = 0
    @Published var diskTotal: Int64 = 0
    @Published var thermal: ProcessInfo.ThermalState = .nominal
    @Published var pressure: Int = 1
    @Published var apps: [AppUsage] = []
    @Published var uptime: TimeInterval = 0
    @Published var netIn: Double = 0      // byte/giây
    @Published var netOut: Double = 0
    @Published var battery: (percent: Int, charging: Bool, plugged: Bool)?
    @Published var temps = SMCReader.Temps()

    private var prevNet: (i: UInt64, o: UInt64, t: Date)?
    private var prevTicks: (busy: UInt64, total: UInt64)?
    private var timer: Timer?
    private var sampling = false

    func start() {
        guard timer == nil else { return }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Quay lại app thì cập nhật ngay
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    var byCPU: [AppUsage] { apps.sorted { $0.cpu > $1.cpu } }
    var byMem: [AppUsage] { apps.sorted { $0.memBytes > $1.memBytes } }
    var memPercent: Double { memTotal == 0 ? 0 : Double(memUsed) / Double(memTotal) * 100 }
    var diskUsedPercent: Double { diskTotal == 0 ? 0 : Double(diskTotal - diskFree) / Double(diskTotal) * 100 }
    var swapHigh: Bool { swapUsed > memTotal / 2 }
    var uptimeDays: Int { Int(uptime / 86_400) }

    private var history: [Double] = []
    private var latestApps: [AppUsage] = []

    /// Giao diện chỉ được cập nhật khi app đang ở trước (đang xem).
    /// Khi app ở phía sau: vẫn đo, vẫn cảnh báo, vẫn cập nhật icon menu bar, nhưng không vẽ lại cửa sổ.
    private var publishedOnce = false
    /// Popup menu bar đang mở (popup có thể hiện mà app không thành app đang dùng)
    var popoverVisible = false { didSet { if popoverVisible { tick() } } }
    private var uiActive: Bool { NSApp.isActive || popoverVisible || !publishedOnce }

    func tick() {
        var newCPU = cpu
        let t = Self.cpuTicks()
        if let p = prevTicks, t.total > p.total, t.busy >= p.busy {
            newCPU = min(100, Double(t.busy - p.busy) / Double(t.total - p.total) * 100)
            history.append(newCPU)
            if history.count > 90 { history.removeFirst(history.count - 90) }
        }
        prevTicks = t
        let th = ProcessInfo.processInfo.thermalState
        LiveCPU.shared.update(cpu: newCPU, thermal: th)

        var inRate = 0.0, outRate = 0.0
        let n = Self.netBytes(), now = Date()
        if let p = prevNet, n.i >= p.i, n.o >= p.o {
            let dt = now.timeIntervalSince(p.t)
            if dt > 0 { inRate = Double(n.i - p.i) / dt; outRate = Double(n.o - p.o) / dt }
        }
        prevNet = (n.i, n.o, now)
        let mem = Self.memoryUsed()
        LiveCPU.shared.update(mem: memTotal == 0 ? 0 : Double(mem) / Double(memTotal) * 100, netIn: inRate, netOut: outRate)

        if uiActive {
            cpu = newCPU
            cpuHistory = history
            thermal = th
            netIn = inRate; netOut = outRate
            battery = Self.batteryInfo()
            memUsed = mem
            swapUsed = Self.swapUsed()
            // statfs: nhẹ, giống lệnh df (không bắt macOS tính lại dung lượng có thể giải phóng)
            var fs = statfs()
            if statfs("/System/Volumes/Data", &fs) == 0 {
                diskFree = Int64(fs.f_bavail) * Int64(fs.f_bsize)
                diskTotal = Int64(fs.f_blocks) * Int64(fs.f_bsize)
            }
            pressure = Self.pressureLevel()
            uptime = Self.uptimeIncludingSleep()
            publishedOnce = true
        }

        guard !sampling else { return }
        sampling = true
        Task.detached(priority: .utility) {
            let list = ProcSampler.sample()
            let t = SMCReader.shared.read()
            let bat = BatteryReader.read()
            await MainActor.run {
                LiveCPU.shared.update(temps: t)
                LiveCPU.shared.update(battery: bat)
                if self.uiActive || !self.publishedOnce { self.temps = t }
                let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path })
                self.latestApps = list.map { a in
                    var a = a
                    a.quittable = a.bundlePath.map { running.contains($0) } ?? false
                    return a
                }
                if self.uiActive || self.apps.isEmpty { self.apps = self.latestApps }
                self.sampling = false
                HeatAlert.shared.check(apps: self.latestApps, thermal: th)
            }
        }
    }

    func quit(_ app: AppUsage, force: Bool = false) {
        guard let bp = app.bundlePath else { return }
        for ra in NSWorkspace.shared.runningApplications where ra.bundleURL?.standardizedFileURL.path == bp {
            _ = force ? ra.forceTerminate() : ra.terminate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.tick() }
    }

    // MARK: - Đọc số liệu hệ thống

    static func cpuTicks() -> (busy: UInt64, total: UInt64) {
        var n: natural_t = 0
        var info: processor_info_array_t?
        var cnt: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &cnt) == KERN_SUCCESS,
              let info else { return (0, 0) }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(cnt) * MemoryLayout<integer_t>.stride))
        }
        var busy: UInt64 = 0, total: UInt64 = 0
        for i in 0..<Int(n) {
            let b = i * Int(CPU_STATE_MAX)
            let u = UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_USER)]))
            let s = UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_SYSTEM)]))
            let ni = UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_IDLE)]))
            busy += u + s + ni
            total += u + s + ni + idle
        }
        return (busy, total)
    }

    /// "Memory Used" như Activity Monitor: app memory + wired + compressed.
    static func memoryUsed() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let page = UInt64(vm_kernel_page_size)
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = internalPages > purgeable ? internalPages - purgeable : 0
        return (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
    }

    static func swapUsed() -> UInt64 {
        var s = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &s, &size, nil, 0) == 0 else { return 0 }
        return s.xsu_used
    }

    /// Tổng byte nhận/gửi qua mọi card mạng (trừ loopback).
    static func netBytes() -> (i: UInt64, o: UInt64) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return (0, 0) }
        defer { freeifaddrs(ifaddr) }
        var i: UInt64 = 0, o: UInt64 = 0
        var p = ifaddr
        while let a = p {
            let f = a.pointee
            if let addr = f.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let data = f.ifa_data,
               !String(cString: f.ifa_name).hasPrefix("lo") {
                let d = data.assumingMemoryBound(to: if_data.self).pointee
                i += UInt64(d.ifi_ibytes); o += UInt64(d.ifi_obytes)
            }
            p = f.ifa_next
        }
        return (i, o)
    }

    static func batteryInfo() -> (percent: Int, charging: Bool, plugged: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  let cap = d[kIOPSCurrentCapacityKey] as? Int, let mx = d[kIOPSMaxCapacityKey] as? Int, mx > 0 else { continue }
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let plugged = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return (cap * 100 / mx, charging, plugged)
        }
        return nil
    }

    /// Thời gian từ lúc bật máy, tính cả lúc ngủ (giống lệnh uptime).
    static func uptimeIncludingSleep() -> TimeInterval {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return ProcessInfo.processInfo.systemUptime }
        return Date().timeIntervalSince1970 - Double(tv.tv_sec)
    }

    /// 1 = bình thường, 2 = cảnh báo, 4 = nguy hiểm
    static func pressureLevel() -> Int {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &v, &size, nil, 0)
        return Int(v)
    }
}

// MARK: - Docker

struct Container: Identifiable {
    let id: String
    let memText: String
    let memMB: Double
    let cpuText: String
}

@MainActor
final class DockerModel: ObservableObject {
    @Published var containers: [Container] = []
    @Published var available = true
    @Published var loading = false

    func refresh() {
        guard !loading else { return }
        loading = true
        Task.detached(priority: .utility) {
            let r = Shell.run("docker stats --no-stream --format '{{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}'")
            let list: [Container] = r.output.split(separator: "\n").compactMap { line in
                let f = line.split(separator: "\t").map(String.init)
                guard f.count >= 3 else { return nil }
                let used = f[1].components(separatedBy: " / ").first ?? f[1]
                let num = Double(used.trimmingCharacters(in: CharacterSet(charactersIn: "0123456789.").inverted)) ?? 0
                let mb = used.contains("GiB") ? num * 1024 : used.contains("KiB") ? num / 1024 : num
                return Container(id: f[0], memText: used, memMB: mb, cpuText: f[2])
            }.sorted { $0.memMB > $1.memMB }
            await MainActor.run {
                self.available = r.status == 0
                self.containers = list
                self.loading = false
            }
        }
    }

    func stop(_ name: String) {
        Task.detached {
            Shell.run("docker stop '\(name.replacingOccurrences(of: "'", with: ""))'")
            await MainActor.run { self.refresh() }
        }
    }
}

/// Số liệu nhỏ cho thanh menu bar, cập nhật cả khi app ở phía sau.
@MainActor
final class LiveCPU: ObservableObject {
    static let shared = LiveCPU()
    @Published private(set) var cpu: Double = 0
    @Published private(set) var thermal: ProcessInfo.ThermalState = .nominal
    @Published private(set) var memPercent: Double = 0
    @Published private(set) var cpuTemp: Double?
    @Published private(set) var gpuTemp: Double?
    @Published private(set) var netIn: Double = 0
    @Published private(set) var netOut: Double = 0
    @Published private(set) var battery: BatteryInfo?

    func update(battery b: BatteryInfo?) { if b != battery { battery = b } }

    func update(cpu c: Double, thermal t: ProcessInfo.ThermalState) {
        if Int(c) != Int(cpu) { cpu = c }
        if t != thermal { thermal = t }
    }
    func update(mem m: Double, netIn i: Double, netOut o: Double) {
        if Int(m) != Int(memPercent) { memPercent = m }
        if fmtSpeed(i) != fmtSpeed(netIn) { netIn = i }
        if fmtSpeed(o) != fmtSpeed(netOut) { netOut = o }
    }
    func update(temps: SMCReader.Temps) {
        if temps.cpu.map(Int.init) != cpuTemp.map(Int.init) { cpuTemp = temps.cpu }
        if temps.gpu.map(Int.init) != gpuTemp.map(Int.init) { gpuTemp = temps.gpu }
    }
}
