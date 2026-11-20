import AppKit
import SystemConfiguration

/// Captures the game's traffic (TCP port 2050) with libpcap and feeds GuardTraffic.swift (issue #61). Started by the
/// app that launched the game, so only one app captures; it ends when the game exits. Reading /dev/bpf needs
/// Wireshark's ChmodBPF (RealmHound needs it too).
///
/// Phase A of #61 writes traffic-loot-<started>-<pid>.tsv, which the importer skips (it reads only loot-*), so it can be
/// compared with the guard's own loot file before the hooks go.
enum TrafficCapture {
    static let port: UInt16 = 2050

    /// Waits for the game the launcher starts, then captures until it exits. Returns at once.
    static func start(logs: URL, portals: Set<Int>, build: String) {
        let started = Date().timeIntervalSince1970
        Thread.detachNewThread {
            var pid: Int32 = 0
            for _ in 0..<1200 {   // the game starts after Play in DECA's launcher; give up after 10 minutes
                if let game = NSWorkspace.shared.runningApplications.first(where: { $0.executableURL?.lastPathComponent == LaunchPlan.gameProcess }) {
                    pid = game.processIdentifier; break
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
            guard pid > 0 else { return }
            let out = logs.appendingPathComponent(String(format: "traffic-loot-%.0f-%d.tsv", started, pid))
            let hits = { () -> URL? in
                let names = (try? FileManager.default.contentsOfDirectory(atPath: logs.path)) ?? []
                return names.first { $0.hasPrefix("hits-") && $0.hasSuffix("-\(pid).tsv") }.map(logs.appendingPathComponent)
            }
            var error = [CChar](repeating: 0, count: Int(PCAP_ERRBUF_SIZE))
            let device = primaryInterface() ?? "en0"
            guard let handle = pcap_create(device, &error) else {
                return write(out, started: started, pid: pid, build: build, problem: "pcap_create \(device): \(String(cString: error))")
            }
            pcap_set_snaplen(handle, 262_144)
            pcap_set_immediate_mode(handle, 1)
            pcap_set_buffer_size(handle, 16 << 20)
            pcap_set_timeout(handle, 100)
            if pcap_activate(handle) < 0 {
                let why = String(cString: pcap_geterr(handle))
                pcap_close(handle)
                return write(out, started: started, pid: pid, build: build,
                             problem: "can't capture on \(device): \(why) (is ChmodBPF installed?)")
            }
            run(handle, out: out, started: started, pid: pid, build: build, portals: portals, hits: hits,
                alive: { guard_process_alive(pid) != 0 })
            pcap_close(handle)
        }
    }

    /// Decodes a saved capture, as `start` would live: for comparing a session again after a decoder change.
    static func replay(pcap file: String, out: URL, hits: URL?, portals: Set<Int>) -> String? {
        var error = [CChar](repeating: 0, count: Int(PCAP_ERRBUF_SIZE))
        guard let handle = pcap_open_offline(file, &error) else { return String(cString: error) }
        defer { pcap_close(handle) }
        run(handle, out: out, started: 0, pid: 0, build: "replay", portals: portals, hits: { hits }, alive: { true })
        return nil
    }

    private static func write(_ out: URL, started: Double, pid: Int32, build: String, problem: String) {
        let text = "loot_session\t\(TrafficLoot.format)\t\(build)\t\(String(format: "%.3f", started))\t\(pid)\n" +
            "status\t\(String(format: "%.3f", Date().timeIntervalSince1970))\trefused\t\(TrafficLoot.clean(problem))\n"
        try? text.write(to: out, atomically: true, encoding: .utf8)
    }

    private static func primaryInterface() -> String? {
        let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        return global?["PrimaryInterface"] as? String
    }

    /// Both directions of one connection; each map is a new connection with fresh ciphers.
    private struct Connection { var incoming = TrafficFlow(outgoing: false), outgoing = TrafficFlow(outgoing: true), reported = false }

    private static func run(_ handle: OpaquePointer, out: URL, started: Double, pid: Int32, build: String, portals: Set<Int>,
                            hits hitsFile: () -> URL?, alive: () -> Bool) {
        guard FileManager.default.createFile(atPath: out.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let file = try? FileHandle(forWritingTo: out) else { return }
        defer { try? file.close() }
        var buffer = ""
        func emit(_ line: String) { buffer += line }
        func drain() { if !buffer.isEmpty { file.write(Data(buffer.utf8)); buffer = "" } }
        emit("loot_session\t\(TrafficLoot.format)\t\(build)\t\(String(format: "%.3f", started))\t\(pid)\n")

        var program = bpf_program()
        if pcap_compile(handle, &program, "tcp port \(port)", 1, PCAP_NETMASK_UNKNOWN) == 0 {
            pcap_setfilter(handle, &program)
            pcap_freecode(&program)
        }
        let link = pcap_datalink(handle)
        let loot = TrafficLoot(portals: portals, emit: emit)
        var hits = TrafficHits(), hitsHandle: FileHandle?, mapStart = 0.0
        loot.projectile = { hits.damage($0, from: $1, to: $2) }
        var connections: [String: Connection] = [:]
        var lastTime = 0.0, lastCheck = Date().timeIntervalSince1970, decoded = 0

        func readHits() {
            if hitsHandle == nil, let url = hitsFile() { hitsHandle = try? FileHandle(forReadingFrom: url) }
            if let data = hitsHandle?.readDataToEndOfFile(), !data.isEmpty { hits.add(String(decoding: data, as: UTF8.self)) }
        }

        var header: UnsafeMutablePointer<pcap_pkthdr>?, bytes: UnsafePointer<UInt8>?
        while true {
            let result = pcap_next_ex(handle, &header, &bytes)
            if result == -2 { break }   // end of a saved capture
            if result < 0 { emit("status\t\(String(format: "%.3f", Date().timeIntervalSince1970))\tcapture_error \(TrafficLoot.clean(String(cString: pcap_geterr(handle))))\n"); break }
            let now = Date().timeIntervalSince1970
            if now - lastCheck >= 1 {
                lastCheck = now
                if !alive() { break }
            }
            guard result == 1, let h = header?.pointee, let bytes else {
                readHits(); loot.flush(now: now); drain(); continue   // live only: a saved capture never times out
            }
            let time = Double(h.ts.tv_sec) + Double(h.ts.tv_usec) / 1e6
            lastTime = time
            guard let seg = Segment(link: link, bytes: Array(UnsafeBufferPointer(start: bytes, count: Int(h.caplen)))) else { continue }
            let incoming = seg.sourcePort == port
            var c = connections[seg.key] ?? Connection()
            if seg.syn && !seg.ack { c = Connection() }   // a new connection under a reused port starts over
            if seg.syn { if incoming { c.incoming.syn(seq: seg.seq) } else { c.outgoing.syn(seq: seg.seq) } }
            let messages = incoming ? c.incoming.segment(seq: seg.seq, payload: seg.payload) : c.outgoing.segment(seq: seg.seq, payload: seg.payload)
            if !messages.isEmpty { readHits() }
            for m in messages {
                guard TrafficPacket.reads(type: m.type, outgoing: !incoming) else { continue }
                guard let packet = TrafficPacket.parse(type: m.type, payload: m.payload, outgoing: !incoming) else { loot.failed(type: m.type, time: time); continue }
                if case .createSuccess = packet { hits.forget(before: mapStart); mapStart = time }   // keep one map back for held kills
                loot.handle(packet, time: time)
                decoded += 1
            }
            if !c.reported, let why = c.incoming.broken ?? c.outgoing.broken {
                c.reported = true
                loot.gap(why, time: time)
            }
            connections[seg.key] = c   // kept after FIN: the other side's last segments still come; a new SYN replaces it
            if buffer.utf8.count > 1 << 16 { drain() }
        }
        readHits()
        loot.flush(now: .infinity, all: true)
        var stats = pcap_stat()
        let dropped = pcap_stats(handle, &stats) == 0 ? Int(stats.ps_drop) : 0
        if dropped > 0 { emit("gap\t\(String(format: "%.3f", lastTime))\t\(dropped)\tpcap_dropped\n") }
        emit("loot_summary\t\(String(format: "%.3f", Date().timeIntervalSince1970))\tsource=traffic\tkills=\(loot.kills)\tbags=\(loot.bagCount)" +
             "\tportals=\(loot.portalCount)\tmessages=\(decoded)\tpcap_dropped=\(dropped)\n")
        emit("status\t\(String(format: "%.3f", Date().timeIntervalSince1970))\tcomplete\n")
        drain()
    }
}

/// One captured TCP segment: Ethernet, loopback or raw IP; IPv4 or IPv6. The payload's length comes from the IP header,
/// not the capture, which can carry Ethernet padding.
struct Segment {
    var key: String, sourcePort: UInt16, seq: UInt32, syn: Bool, ack: Bool, payload: [UInt8]

    init?(link: Int32, bytes b: [UInt8]) {
        func u16(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
        var ip: Int
        switch link {
        case DLT_EN10MB:
            guard b.count >= 14 else { return nil }
            ip = 14
            if u16(12) == 0x8100 { ip = 18 }
        case DLT_NULL, 108: ip = 4   // 108: DLT_LOOP
        case DLT_RAW, 12, 14: ip = 0
        default: return nil
        }
        guard b.count > ip else { return nil }
        let version = b[ip] >> 4
        var tcp: Int, end: Int, source: ArraySlice<UInt8>, dest: ArraySlice<UInt8>
        if version == 4 {
            guard b.count >= ip + 20, b[ip + 9] == 6 else { return nil }
            tcp = ip + Int(b[ip] & 15) * 4
            end = ip + u16(ip + 2)
            (source, dest) = (b[ip + 12..<ip + 16], b[ip + 16..<ip + 20])
        } else if version == 6 {
            guard b.count >= ip + 40, b[ip + 6] == 6 else { return nil }   // shortcut: no extension headers; the game sends none
            tcp = ip + 40
            end = tcp + u16(ip + 4)
            (source, dest) = (b[ip + 8..<ip + 24], b[ip + 24..<ip + 40])
        } else { return nil }
        end = min(end, b.count)
        guard end >= tcp + 20 else { return nil }
        let sourcePort = UInt16(u16(tcp)), destPort = UInt16(u16(tcp + 2))
        let data = tcp + Int(b[tcp + 12] >> 4) * 4
        guard data <= end else { return nil }
        let flags = b[tcp + 13]
        // The client's end names the connection, so both directions share a key.
        let client = sourcePort == TrafficCapture.port ? (dest, destPort, source) : (source, sourcePort, dest)
        key = client.0.map(String.init).joined(separator: ".") + ":\(client.1)>" + client.2.map(String.init).joined(separator: ".")
        self.sourcePort = sourcePort
        seq = b[tcp + 4..<tcp + 8].reduce(0) { $0 << 8 | UInt32($1) }
        (syn, ack) = (flags & 2 != 0, flags & 16 != 0)
        payload = Array(b[data..<end])
    }
}
