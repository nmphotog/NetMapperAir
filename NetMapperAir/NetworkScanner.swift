import Foundation
import Network
import Darwin
import UIKit

// MARK: - IPv4 helpers

enum IPv4 {
    static func string(_ v: UInt32) -> String {
        "\((v >> 24) & 0xff).\((v >> 16) & 0xff).\((v >> 8) & 0xff).\(v & 0xff)"
    }
}

// MARK: - Local interface

struct NetworkInterface {
    let name: String
    let address: UInt32   // host byte order
    let netmask: UInt32   // host byte order

    var prefixLength: Int { netmask.nonzeroBitCount }
    var network: UInt32 { address & netmask }
    var broadcast: UInt32 { network | ~netmask }
    var cidr: String { "\(IPv4.string(network))/\(prefixLength)" }

    /// The active Wi-Fi / Ethernet IPv4 interface (en*). Cellular (pdp_ip*) is never scanned.
    static func primary() -> NetworkInterface? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }

        var found: [NetworkInterface] = []
        var ptr = head
        while let p = ptr {
            let ifa = p.pointee
            ptr = ifa.ifa_next

            let flags = Int32(ifa.ifa_flags)
            guard let addr = ifa.ifa_addr, let mask = ifa.ifa_netmask,
                  addr.pointee.sa_family == sa_family_t(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0
            else { continue }

            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let a = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if (a >> 16) == 0xA9FE { continue } // skip 169.254.x.x link-local
            found.append(NetworkInterface(name: name, address: a, netmask: m))
        }
        return found.first { $0.name == "en0" } ?? found.first
    }
}

// MARK: - Host model

struct DiscoveredHost: Identifiable, Hashable {
    let address: UInt32
    var hostname: String?
    var latency: Double?
    var isThisDevice = false
    var deviceSymbol = "desktopcomputer"

    var id: UInt32 { address }
    var ip: String { IPv4.string(address) }
    var displayName: String {
        if let hostname { return hostname }
        if isThisDevice { return "This Device" }
        return "Unknown"
    }
    var symbol: String { deviceSymbol }
}

// MARK: - Probing

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

enum Prober {
    /// iOS can't read the ARP table, so discovery relies entirely on these probes.
    /// A host is "alive" if any port accepts OR actively refuses the connection.
    static let ports: [UInt16] = [80, 443, 22, 445, 139, 548, 62078, 5000, 7000, 8080]

    static func isAlive(_ ip: String, timeout: TimeInterval = 1.0) async -> Double? {
        await withTaskGroup(of: Double?.self) { group in
            for port in ports {
                group.addTask { await probe(ip, port: port, timeout: timeout) }
            }
            var best: Double?
            for await r in group {
                if let r { best = min(best ?? r, r) }
            }
            return best
        }
    }

    static func probe(_ ip: String, port: UInt16, timeout: TimeInterval) async -> Double? {
        await withCheckedContinuation { cont in
            let once = ResumeOnce()
            let start = DispatchTime.now().uptimeNanoseconds
            let queue = DispatchQueue(label: "probe.\(ip).\(port)")
            let params = NWParameters.tcp
            let conn = NWConnection(host: NWEndpoint.Host(ip),
                                    port: NWEndpoint.Port(rawValue: port)!,
                                    using: params)

            let finish: (Bool) -> Void = { alive in
                guard once.claim() else { return }
                conn.stateUpdateHandler = nil
                conn.cancel()
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                cont.resume(returning: alive ? ms : nil)
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .waiting(let error):
                    if case .posix(.ECONNREFUSED) = error { finish(true) }
                case .failed(let error):
                    if case .posix(.ECONNREFUSED) = error { finish(true) } else { finish(false) }
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }
}

// MARK: - Name lookup

enum Resolver {
    static func reverseDNS(_ ip: UInt32) -> String? {
        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_addr.s_addr = ip.bigEndian
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = withUnsafePointer(to: &sin) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size),
                            &buf, socklen_t(buf.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard rc == 0 else { return nil }
        let name = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return name.hasSuffix(".") ? String(name.dropLast()) : name
    }
}

// MARK: - Scanner

@MainActor
final class ScannerModel: ObservableObject {
    @Published private(set) var hosts: [DiscoveredHost] = []
    @Published private(set) var isScanning = false
    @Published private(set) var progress = 0.0
    @Published private(set) var status = "Ready"
    @Published private(set) var interface: NetworkInterface?

    private var task: Task<Void, Never>?
    private let maxConcurrentHosts = 16

    func toggle() { isScanning ? stop() : start() }

    func stop() {
        task?.cancel()
        status = "Stopping…"
    }

    func start() {
        guard !isScanning else { return }
        guard let iface = NetworkInterface.primary() else {
            status = "Connect to Wi-Fi to scan your network."
            return
        }
        interface = iface
        hosts = []
        progress = 0
        isScanning = true
        task = Task {
            await run(iface)
            isScanning = false
        }
    }

    /// Awaitable scan for pull-to-refresh.
    func refresh() async {
        if isScanning { return }
        start()
        await task?.value
    }

    private func run(_ iface: NetworkInterface) async {
        // Large subnets (bigger than /22) are limited to this device's /24.
        var first = iface.network &+ 1
        var last = iface.broadcast &- 1
        if iface.prefixLength < 22 {
            let base = iface.address & 0xFFFF_FF00
            first = base + 1
            last = base + 254
        }
        guard first <= last else { status = "Subnet too small to scan."; return }

        let selfSymbol = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        hosts = [DiscoveredHost(address: iface.address, hostname: UIDevice.current.name,
                                isThisDevice: true, deviceSymbol: selfSymbol)]

        let targets = Array(first...last).filter { $0 != iface.address }
        status = "Scanning \(targets.count) addresses…"
        var done = 0

        await withTaskGroup(of: (UInt32, Double?).self) { group in
            var it = targets.makeIterator()
            for _ in 0..<maxConcurrentHosts {
                guard let t = it.next() else { break }
                group.addTask { (t, await Prober.isAlive(IPv4.string(t))) }
            }
            while let result = await group.next() {
                done += 1
                progress = Double(done) / Double(targets.count)
                if let latency = result.1 { add(result.0, latency: latency) }
                if Task.isCancelled { continue } // drain without adding more work
                if let t = it.next() {
                    group.addTask { (t, await Prober.isAlive(IPv4.string(t))) }
                }
            }
        }

        status = "Resolving names…"
        let addresses = hosts.filter { $0.hostname == nil }.map(\.address)
        let names = await withTaskGroup(of: (UInt32, String?).self) { group -> [UInt32: String] in
            for a in addresses { group.addTask { (a, Resolver.reverseDNS(a)) } }
            var d: [UInt32: String] = [:]
            for await r in group { if let n = r.1 { d[r.0] = n } }
            return d
        }
        for (a, n) in names {
            if let i = hosts.firstIndex(where: { $0.address == a }) { hosts[i].hostname = n }
        }

        progress = 1
        let others = hosts.count - 1
        if others == 0 && !Task.isCancelled {
            status = "No other devices found. If you just allowed Local Network access, scan again."
        } else {
            let summary = "Found \(hosts.count) device\(hosts.count == 1 ? "" : "s") on \(iface.cidr)"
            status = (Task.isCancelled ? "Stopped. " : "") + summary
        }
    }

    private func add(_ ip: UInt32, latency: Double) {
        if let i = hosts.firstIndex(where: { $0.address == ip }) {
            hosts[i].latency = latency
        } else {
            hosts.append(DiscoveredHost(address: ip, latency: latency))
            hosts.sort { $0.address < $1.address }
        }
    }
}
