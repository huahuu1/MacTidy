import Foundation
import IOKit

/// Đọc nhiệt độ từ SMC (System Management Controller), không cần quyền admin.
/// Apple Silicon: Tp* = nhân P, Te* = nhân E, Tg* = GPU. Giá trị kiểu "flt " (Float 4 byte).
/// Đây là API không công khai của Apple: có thể đổi tên khoá ở chip mới, khi đó app chỉ hiện "—".
final class SMCReader {
    static let shared = SMCReader()

    private typealias Bytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                               UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
    private struct Vers { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
    private struct Limit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
    private struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0; var attributes: UInt8 = 0 }
    private struct Param {     // phải đúng 80 byte như struct C của AppleSMC
        var key: UInt32 = 0
        var vers = Vers()
        var limit = Limit()
        var info = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0, status: UInt8 = 0, data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: Bytes = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    }

    private var conn: io_connect_t = 0
    private var cpuKeys: [(UInt32, UInt32)] = []   // (key, dataSize)
    private var gpuKeys: [(UInt32, UInt32)] = []
    private var batteryKeys: [(UInt32, UInt32)] = []
    private let lock = NSLock()
    private(set) var ready = false

    private init() {
        guard MemoryLayout<Param>.stride == 80 else { return }
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return }
        defer { IOObjectRelease(svc) }
        guard IOServiceOpen(svc, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return }
        discover()
    }

    private static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
    private static func name(_ v: UInt32) -> String {
        String(bytes: [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)], encoding: .ascii) ?? ""
    }

    private func call(_ input: inout Param) -> Param? {
        var out = Param()
        var size = MemoryLayout<Param>.stride
        let r = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<Param>.stride, &out, &size)
        return r == KERN_SUCCESS && out.result == 0 ? out : nil
    }

    private func info(_ key: UInt32) -> KeyInfo? { var p = Param(); p.key = key; p.data8 = 9; return call(&p)?.info }

    private func readBytes(_ key: UInt32, size: UInt32) -> [UInt8]? {
        var p = Param(); p.key = key; p.info.dataSize = size; p.data8 = 5
        guard let o = call(&p) else { return nil }
        return withUnsafeBytes(of: o.bytes) { Array($0.prefix(Int(size))) }
    }

    /// Quét toàn bộ khoá một lần (khoảng 60 ms) để tìm khoá nhiệt độ CPU và GPU có trên máy này.
    private func discover() {
        guard let i = info(Self.fourCC("#KEY")), let b = readBytes(Self.fourCC("#KEY"), size: i.dataSize) else { return }
        let count = b.reduce(0) { $0 << 8 | UInt32($1) }
        let flt = Self.fourCC("flt ")
        for idx in 0..<count {
            var p = Param(); p.data8 = 8; p.data32 = idx
            guard let k = call(&p)?.key else { continue }
            let n = Self.name(k)
            let isCPU = n.hasPrefix("Tp") || n.hasPrefix("Te")
            let isGPU = n.hasPrefix("Tg")
            let isBat = n.hasPrefix("TB") && n.hasSuffix("T")
            guard isCPU || isGPU || isBat, let inf = info(k), inf.dataType == flt, inf.dataSize == 4 else { continue }
            if isCPU { cpuKeys.append((k, 4)) } else if isGPU { gpuKeys.append((k, 4)) } else { batteryKeys.append((k, 4)) }
        }
        ready = !cpuKeys.isEmpty
    }

    private func average(_ keys: [(UInt32, UInt32)]) -> (avg: Double, max: Double)? {
        var sum = 0.0, n = 0.0, mx = 0.0
        for (k, s) in keys {
            guard let b = readBytes(k, size: s), b.count == 4 else { continue }
            let v = Double(b.withUnsafeBytes { $0.load(as: Float.self) })
            guard v > 5, v < 130 else { continue }    // bỏ cảm biến tắt hoặc lỗi
            sum += v; n += 1; mx = max(mx, v)
        }
        return n > 0 ? (sum / n, mx) : nil
    }

    func batteryTemp() -> Double? {
        lock.lock(); defer { lock.unlock() }
        return ready ? average(batteryKeys)?.avg : nil
    }

    struct Temps { var cpu: Double?; var cpuMax: Double?; var gpu: Double? }

    func read() -> Temps {
        lock.lock(); defer { lock.unlock() }
        guard ready else { return Temps() }
        let c = average(cpuKeys), g = average(gpuKeys)
        return Temps(cpu: c?.avg, cpuMax: c?.max, gpu: g?.avg)
    }
}
