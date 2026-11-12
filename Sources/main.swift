import Cocoa

// RouterStats: ASUS router stats in the menu bar (iStat style) via the router's web API.
// Router address, username and ping target are in UserDefaults; the password is in the Keychain.
// Ping runs locally from this Mac; the router is only asked for its own stats.
var pingTarget: String { Config.current?.pingTarget ?? "8.8.8.8" }
let orange = NSColor(srgbRed: 0.96, green: 0.58, blue: 0.20, alpha: 1)
let blue = NSColor(srgbRed: 0.20, green: 0.55, blue: 1.0, alpha: 1)
let green = NSColor(srgbRed: 0.30, green: 0.78, blue: 0.40, alpha: 1)
let track = NSColor.gray.withAlphaComponent(0.35)
let historyLen = 120      // samples shown in the panel cards

struct Device { var name: String, ip: String, band: String, rssi: Int?, wired: Bool }

struct Sample {
    var cpu: Double = 0, cores: [Double] = [], memUsed: Double = 0, memTotal: Double = 1
    var down: Double = 0, up: Double = 0, uptime: Int = 0
    var temp: Double = 0
    var ping: Double = -1, dev: Double = -1, loss: Double = 0          // -1 = no reply
    var online = true, publicIP = ""
    var devices: [Device] = [], ports: [(String, String)] = []
    var firmware = "", update = false
    var mem: Double { memUsed / memTotal }
}

// MARK: drawing helpers
func drawBars(_ vals: [Double], in r: NSRect, color: NSColor, max m: Double = 100, gap: CGFloat = 0) {
    guard !vals.isEmpty else { return }
    let w = r.width / CGFloat(vals.count)
    color.setFill()
    for (i, v) in vals.enumerated() where v >= 0 {
        let h = max(0, min(1, v / m)) * r.height
        NSRect(x: r.minX + CGFloat(i) * w, y: r.minY, width: max(w - gap, 0.5), height: h).fill()
    }
}

func drawRing(center c: NSPoint, radius: CGFloat, width: CGFloat, frac: Double, color: NSColor) {
    let t = NSBezierPath(); t.appendArc(withCenter: c, radius: radius, startAngle: 0, endAngle: 360)
    t.lineWidth = width; track.setStroke(); t.stroke()
    let a = NSBezierPath()
    a.appendArc(withCenter: c, radius: radius, startAngle: 90, endAngle: 90 - 360 * CGFloat(max(0, min(1, frac))), clockwise: true)
    a.lineWidth = width; a.lineCapStyle = .round; color.setStroke(); a.stroke()
}

func drawPie(center c: NSPoint, radius: CGFloat, frac: Double, color: NSColor) {
    let bg = NSBezierPath(ovalIn: NSRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
    track.setFill(); bg.fill()
    let p = NSBezierPath(); p.move(to: c)
    p.appendArc(withCenter: c, radius: radius, startAngle: 90, endAngle: 90 - 360 * CGFloat(max(0, min(1, frac))), clockwise: true)
    p.close(); color.setFill(); p.fill()
}

func text(_ s: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSAttributedString {
    NSAttributedString(string: s, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight), .foregroundColor: color])
}
func drawText(_ s: NSAttributedString, at p: NSPoint, align: NSTextAlignment = .left, maxWidth: CGFloat? = nil) {
    var s = s
    if let mw = maxWidth, s.size().width > mw {   // truncate with …
        let m = NSMutableAttributedString(attributedString: s)
        while m.length > 1 && m.size().width > mw { m.deleteCharacters(in: NSRange(location: m.length - 2, length: 1)); m.replaceCharacters(in: NSRange(location: m.length - 1, length: 1), with: "…") }
        s = m
    }
    let w = s.size().width
    s.draw(at: NSPoint(x: align == .right ? p.x - w : align == .center ? p.x - w / 2 : p.x, y: p.y))
}
func rate(_ b: Double) -> String {
    let u = ["B/s", "KB/s", "MB/s", "GB/s"]; var v = b, i = 0
    while v >= 1000 && i < 3 { v /= 1000; i += 1 }
    return String(format: v < 10 && i > 0 ? "%.1f %@" : "%.0f %@", v, u[i])
}
func ms(_ v: Double) -> String { v < 0 ? "–" : String(format: v < 10 ? "%.1f ms" : "%.0f ms", v) }
func signalColor(_ rssi: Int?) -> NSColor {
    guard let r = rssi else { return .secondaryLabelColor }
    return r >= -60 ? green : r >= -70 ? orange : .systemRed
}

// MARK: history (timestamped, saved to disk)
// Full 2-second detail for the last day; older samples are averaged into 1-minute points and kept for a week.
let rawAge: Double = 86400
let maxAge: Double = 7 * 86400
let historyURL: URL = {
    let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RouterStats")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d.appendingPathComponent("history.json")
}()
struct History: Codable {
    var t: [Double] = [], cpu: [Double] = [], mem: [Double] = [], down: [Double] = [], up: [Double] = [], cores: [[Double]] = []
    var temp: [Double] = [], ping: [Double] = [], dev: [Double] = [], devices: [Double] = []
    var compacted = 0   // samples [0, compacted) are already 1-minute averages

    init() {}
    init(from d: Decoder) throws {   // tolerate files from older versions
        let c = try d.container(keyedBy: CodingKeys.self)
        t = try c.decode([Double].self, forKey: .t)
        func get(_ k: CodingKeys) -> [Double] { (try? c.decode([Double].self, forKey: k)) ?? Array(repeating: -1, count: t.count) }
        cpu = get(.cpu); mem = get(.mem); down = get(.down); up = get(.up)
        temp = get(.temp); ping = get(.ping); dev = get(.dev); devices = get(.devices)
        cores = (try? c.decode([[Double]].self, forKey: .cores)) ?? []
        compacted = min((try? c.decode(Int.self, forKey: .compacted)) ?? 0, t.count)
    }

    mutating func push(_ s: Sample, at now: Double = Date().timeIntervalSince1970) {
        if cores.count != s.cores.count { self = History(); cores = Array(repeating: [], count: s.cores.count) }
        t.append(now); cpu.append(s.cpu); mem.append(s.mem * 100); down.append(s.down); up.append(s.up)
        temp.append(s.temp); ping.append(s.ping); dev.append(s.dev); devices.append(Double(s.devices.count))
        for i in s.cores.indices { cores[i].append(s.cores[i]) }
        var lo = compacted, hi = t.count          // first index newer than a day (t is sorted)
        while lo < hi { let mid = (lo + hi) / 2; if t[mid] < now - rawAge { lo = mid + 1 } else { hi = mid } }
        let cut = lo
        if cut - compacted > 500 { compact(upTo: cut) }   // in chunks, so this runs about every 15 minutes
    }

    /// Average samples [0, end) into 1-minute points (already-compacted points pass through unchanged)
    /// and drop anything older than `maxAge`.
    mutating func compact(upTo end: Int) {
        let newest = t.last ?? 0
        var nt: [Double] = [], cols: [[Double]] = Array(repeating: [], count: 8 + cores.count)
        func series(_ i: Int) -> [Double] {
            switch i { case 0: return cpu; case 1: return mem; case 2: return down; case 3: return up
                       case 4: return temp; case 5: return ping; case 6: return dev; case 7: return devices
                       default: return cores[i - 8] }
        }
        let all = (0..<cols.count).map(series)   // copies; fine at ~15-minute intervals
        var i = 0
        while i < end {
            let minute = floor(t[i] / 60); var j = i
            while j < end && floor(t[j] / 60) == minute { j += 1 }
            if t[i] >= newest - maxAge {
                nt.append(t[i])
                for c in cols.indices {
                    let vals = all[c][i..<j].filter { $0 >= 0 }   // -1 means "no reading"
                    cols[c].append(vals.isEmpty ? -1 : vals.reduce(0, +) / Double(vals.count))
                }
            }
            i = j
        }
        compacted = nt.count
        t = nt + t[end...]
        cpu = cols[0] + cpu[end...]; mem = cols[1] + mem[end...]; down = cols[2] + down[end...]; up = cols[3] + up[end...]
        temp = cols[4] + temp[end...]; ping = cols[5] + ping[end...]; dev = cols[6] + dev[end...]; devices = cols[7] + devices[end...]
        for k in cores.indices { cores[k] = cols[8 + k] + cores[k][end...] }
    }
    static func load() -> History { (try? JSONDecoder().decode(History.self, from: Data(contentsOf: historyURL))) ?? History() }
    func save() { try? JSONEncoder().encode(self).write(to: historyURL, options: .atomic) }

    // Average `series` into n time buckets covering the last `range` seconds. nil = no data; negative values are skipped.
    func buckets(_ series: [Double], n: Int, range: Double, now: Double = Date().timeIntervalSince1970) -> [Double?] {
        var sum = [Double](repeating: 0, count: n), cnt = [Int](repeating: 0, count: n)
        let start = now - range
        var i = min(t.count, series.count) - 1
        while i >= 0 && t[i] >= start {
            if series[i] >= 0 { let b = min(n - 1, Int((t[i] - start) / range * Double(n))); sum[b] += series[i]; cnt[b] += 1 }
            i -= 1
        }
        return (0..<n).map { cnt[$0] > 0 ? sum[$0] / Double(cnt[$0]) : nil }
    }
}

func drawSplit(down: [Double], up: [Double], in g: NSRect) {
    let m = max((zip(down, up).map { max($0, $1) }).max() ?? 1, 1)
    let w = g.width / CGFloat(max(down.count, 1))
    blue.setFill()
    for (i, v) in down.enumerated() { let h = CGFloat(v / m) * g.height / 2
        NSRect(x: g.minX + CGFloat(i) * w, y: g.midY, width: max(w - 0.5, 0.5), height: h).fill() }
    orange.setFill()
    for (i, v) in up.enumerated() { let h = CGFloat(v / m) * g.height / 2
        NSRect(x: g.minX + CGFloat(i) * w, y: g.midY - h, width: max(w - 0.5, 0.5), height: h).fill() }
}

enum Section: Int, CaseIterable { case cpu, cores, memory, internet, ping, devices, ports, router }
let flyoutSections: Set<Section> = [.cpu, .cores, .memory, .internet, .ping, .devices]

func cardBG(_ r: NSRect, highlighted: Bool) {
    let p = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
    NSColor.labelColor.withAlphaComponent(0.06).setFill(); p.fill()
    if highlighted { p.lineWidth = 1.5; orange.setStroke(); p.stroke() }
}
func header(_ title: String, _ r: NSRect) { drawText(text(title, weight: .semibold, color: orange), at: NSPoint(x: r.minX, y: r.maxY - 15)) }
func padded(_ a: [Double]) -> [Double] { let t = Array(a.suffix(historyLen)); return Array(repeating: -1, count: historyLen - t.count) + t }

// MARK: dropdown panel (iStat-like cards)
final class Panel: NSView {
    var h = History(), s = Sample()
    var hovered: Section? { didSet { if hovered != oldValue { needsDisplay = true; onHover?(hovered) } } }
    var onHover: ((Section?) -> Void)?
    private(set) var rects: [Section: NSRect] = [:]
    static let heights: [Section: CGFloat] = [.cpu: 118, .cores: 84, .memory: 72, .internet: 112, .ping: 96, .devices: 76, .ports: 62, .router: 52]
    static var totalHeight: CGFloat { Section.allCases.reduce(8) { $0 + heights[$1]! + 8 } }

    override init(frame: NSRect) { super.init(frame: frame); layoutCards() }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseMoved(with e: NSEvent) { let p = convert(e.locationInWindow, from: nil); hovered = rects.first { $0.value.contains(p) }?.key }
    override func mouseExited(with e: NSEvent) { hovered = nil }

    func layoutCards() {
        var y = bounds.height - 8
        for sec in Section.allCases { let hh = Panel.heights[sec]!; y -= hh
            rects[sec] = NSRect(x: 8, y: y, width: bounds.width - 16, height: hh); y -= 8 }
    }

    override func draw(_ dirty: NSRect) {
        for sec in Section.allCases {
            let card = rects[sec]!
            cardBG(card, highlighted: sec == hovered && flyoutSections.contains(sec))
            let r = card.insetBy(dx: 4, dy: 8)
            switch sec {
            case .cpu:
                header("CPU", r)
                drawText(text(String(format: "%.0f°   %.0f%%", s.temp, s.cpu), weight: .semibold), at: NSPoint(x: r.maxX, y: r.maxY - 15), align: .right)
                drawBars(padded(h.cpu), in: NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height - 24), color: orange, gap: 0.5)
            case .cores:
                header("CORES", r)
                let slot = r.width / CGFloat(max(s.cores.count, 1))
                for (i, v) in s.cores.enumerated() {
                    let c = NSPoint(x: r.minX + slot * (CGFloat(i) + 0.5), y: r.minY + 22)
                    drawRing(center: c, radius: 17, width: 5, frac: v / 100, color: orange)
                    drawText(text(String(format: "%.0f%%", v), size: 10), at: NSPoint(x: c.x, y: c.y - 6), align: .center)
                }
            case .memory:
                header("MEMORY", r)
                let c = NSPoint(x: r.maxX - 26, y: r.midY)
                drawRing(center: c, radius: 22, width: 6, frac: s.mem, color: orange)
                drawText(text(String(format: "%.0f%%", s.mem * 100), size: 11, weight: .semibold), at: NSPoint(x: c.x, y: c.y - 7), align: .center)
                drawText(text(String(format: "Used  %.0f MB", s.memUsed / 1024)), at: NSPoint(x: r.minX, y: r.minY + 18))
                drawText(text(String(format: "Total %.0f MB", s.memTotal / 1024), color: .secondaryLabelColor), at: NSPoint(x: r.minX, y: r.minY + 2))
            case .internet:
                header("INTERNET", r)
                let st = s.online ? text("● Connected", size: 11, color: green) : text("● Offline", size: 11, color: .systemRed)
                drawText(st, at: NSPoint(x: r.maxX, y: r.maxY - 15), align: .right)
                drawText(text("↓ " + rate(s.down), color: blue), at: NSPoint(x: r.minX, y: r.maxY - 33))
                drawText(text("↑ " + rate(s.up), color: orange), at: NSPoint(x: r.minX + 100, y: r.maxY - 33))
                drawText(text(s.publicIP, size: 11, color: .secondaryLabelColor), at: NSPoint(x: r.maxX, y: r.maxY - 33), align: .right)
                drawSplit(down: padded(h.down).map { max($0, 0) }, up: padded(h.up).map { max($0, 0) },
                          in: NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height - 42))
            case .ping:
                header("PING", r)
                drawText(text(pingTarget, size: 11, color: .secondaryLabelColor), at: NSPoint(x: r.maxX, y: r.maxY - 15), align: .right)
                let cols: [(String, String, NSColor)] = [("Ping", ms(s.ping), orange), ("Deviation", ms(s.dev), blue), ("Loss", String(format: "%.0f%%", s.loss), s.loss > 0 ? .systemRed : .labelColor)]
                let cw = r.width / 3
                for (i, c) in cols.enumerated() {
                    let x = r.minX + cw * CGFloat(i)
                    drawText(text(c.0, size: 10, color: .secondaryLabelColor), at: NSPoint(x: x, y: r.maxY - 33))
                    drawText(text(c.1, size: 13, weight: .semibold, color: c.2), at: NSPoint(x: x, y: r.maxY - 50))
                }
                let pm = max((padded(h.ping).max() ?? 1) * 1.1, 10)
                drawBars(padded(h.ping), in: NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height - 56), color: orange, max: pm, gap: 0.5)
            case .devices:
                header("DEVICES", r)
                drawText(text("\(s.devices.count)", weight: .semibold), at: NSPoint(x: r.maxX, y: r.maxY - 15), align: .right)
                let groups = ["2.4 GHz", "5 GHz", "6 GHz", "Wired"].map { b in (b, s.devices.filter { $0.band == b }.count) }
                let cw = r.width / 4
                for (i, g) in groups.enumerated() {
                    let x = r.minX + cw * CGFloat(i)
                    drawText(text(g.0, size: 10, color: .secondaryLabelColor), at: NSPoint(x: x, y: r.minY + 22))
                    drawText(text("\(g.1)", size: 15, weight: .semibold), at: NSPoint(x: x, y: r.minY + 2))
                }
            case .ports:
                header("PORTS", r)
                let pw = r.width / CGFloat(max(s.ports.count, 1))
                for (i, p) in s.ports.enumerated() {
                    let x = r.minX + pw * CGFloat(i), box = NSRect(x: x + 2, y: r.minY, width: pw - 4, height: 26)
                    let up = p.1 != "–"
                    (up ? orange.withAlphaComponent(0.25) : NSColor.labelColor.withAlphaComponent(0.06)).setFill()
                    NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
                    drawText(text(p.0, size: 9, color: .secondaryLabelColor), at: NSPoint(x: box.midX, y: box.minY + 14), align: .center)
                    drawText(text(p.1, size: 10, weight: .semibold, color: up ? .labelColor : .tertiaryLabelColor), at: NSPoint(x: box.midX, y: box.minY + 1), align: .center)
                }
            case .router:
                let d = s.uptime / 86400, hr = (s.uptime % 86400) / 3600, m = (s.uptime % 3600) / 60
                let u = d > 0 ? "\(d) day\(d == 1 ? "" : "s"), \(hr) hour\(hr == 1 ? "" : "s")" : "\(hr)h \(m)m"
                drawText(text("UPTIME", weight: .semibold, color: orange), at: NSPoint(x: r.minX, y: r.maxY - 15))
                drawText(text(u), at: NSPoint(x: r.maxX, y: r.maxY - 15), align: .right)
                drawText(text("FIRMWARE", weight: .semibold, color: orange), at: NSPoint(x: r.minX, y: r.minY))
                drawText(text(s.firmware + (s.update ? "  ● Update" : ""), size: 11, color: s.update ? orange : .secondaryLabelColor),
                         at: NSPoint(x: r.maxX, y: r.minY), align: .right)
            }
        }
    }
}

// MARK: hover flyout (history for the hovered section, adjustable range, crosshair tooltip)
let ranges: [(String, Double)] = [("10 Minutes", 600), ("1 Hour", 3600), ("3 Hours", 10800), ("6 Hours", 21600), ("12 Hours", 43200), ("24 Hours", 86400), ("3 Days", 259200), ("7 Days", 604800)]
func drawOpt(_ vals: [Double?], in g: NSRect, color: NSColor, max m: Double = 100) {
    let w = g.width / CGFloat(vals.count); color.setFill()
    for (i, v) in vals.enumerated() { guard let v else { continue }
        NSRect(x: g.minX + CGFloat(i) * w, y: g.minY, width: max(w - 1, 0.5), height: max(0, min(1, v / m)) * g.height).fill() }
}

final class Flyout: NSView {
    static let graphSize = NSSize(width: 391, height: 216)
    var section: Section = .cpu { didSet { needsDisplay = true } }
    var h = History(), s = Sample()
    var rangeIdx = UserDefaults.standard.object(forKey: "range") as? Int ?? 1 { didSet { UserDefaults.standard.set(rangeIdx, forKey: "range"); needsDisplay = true } }
    var hoverX: CGFloat? { didSet { needsDisplay = true } }
    var range: Double { ranges[rangeIdx].1 }
    var graph: NSRect { let r = bounds.insetBy(dx: 16, dy: 14); return NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height - 30) }
    var pickerRect: NSRect { let s = text(ranges[rangeIdx].0).size(); return NSRect(x: bounds.maxX - 16 - s.width - 16, y: bounds.maxY - 34, width: s.width + 18, height: 22) }
    let barW: CGFloat = 4

    // Device list rows, sorted by band then signal.
    var deviceRows: [Device] {
        let order = ["6 GHz": 0, "5 GHz": 1, "2.4 GHz": 2, "Wired": 3]
        return s.devices.sorted { (order[$0.band] ?? 9, -($0.rssi ?? -999), $0.name) < (order[$1.band] ?? 9, -($1.rssi ?? -999), $1.name) }
    }
    static let rowH: CGFloat = 18
    func preferredSize() -> NSSize {
        section == .devices ? NSSize(width: 391, height: 56 + CGFloat(max(deviceRows.count, 1)) * Flyout.rowH) : Flyout.graphSize
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with e: NSEvent) { let p = convert(e.locationInWindow, from: nil); hoverX = section != .devices && graph.contains(p) ? p.x : nil }
    override func mouseExited(with e: NSEvent) { hoverX = nil }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        guard section != .devices, pickerRect.contains(p) else { return }
        let m = NSMenu()
        for (i, r) in ranges.enumerated() {
            let it = NSMenuItem(title: r.0, action: #selector(pick(_:)), keyEquivalent: ""); it.tag = i; it.target = self
            it.state = i == rangeIdx ? .on : .off; m.addItem(it)
        }
        m.popUp(positioning: m.item(at: rangeIdx), at: NSPoint(x: pickerRect.minX, y: pickerRect.minY + 4), in: self)
    }
    @objc func pick(_ i: NSMenuItem) { rangeIdx = i.tag }

    var n: Int { Int(graph.width / barW) }
    func series() -> [(String, NSColor, [Double?], (Double) -> String)] {
        let pct = { (v: Double) in String(format: "%.0f%%", v) }
        switch section {
        case .cpu: return [("CPU", orange, h.buckets(h.cpu, n: n, range: range), pct),
                           ("Temp", .secondaryLabelColor, h.buckets(h.temp, n: n, range: range), { String(format: "%.0f°C", $0) })]
        case .memory: return [("Memory", orange, h.buckets(h.mem, n: n, range: range), pct)]
        case .internet: return [("Download", blue, h.buckets(h.down, n: n, range: range), rate), ("Upload", orange, h.buckets(h.up, n: n, range: range), rate)]
        case .ping: return [("Ping", orange, h.buckets(h.ping, n: n, range: range), ms), ("Deviation", blue, h.buckets(h.dev, n: n, range: range), ms)]
        case .cores: return h.cores.enumerated().map { ("Core \($0.offset + 1)", orange, h.buckets($0.element, n: n, range: range), pct) }
        default: return []
        }
    }

    override func draw(_ dirty: NSRect) {
        let titles: [Section: String] = [.cpu: "CPU", .cores: "CORES", .memory: "MEMORY", .internet: "INTERNET", .ping: "PING", .devices: "DEVICES"]
        drawText(text(titles[section] ?? "", weight: .semibold, color: orange), at: NSPoint(x: 16, y: bounds.maxY - 30))
        if section == .devices { drawDevices(); return }
        drawText(text(ranges[rangeIdx].0), at: NSPoint(x: pickerRect.minX + 2, y: pickerRect.minY + 3))
        if let img = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold).applying(.init(hierarchicalColor: .labelColor))) {
            img.draw(in: NSRect(x: pickerRect.maxX - 10, y: pickerRect.midY - 6, width: 9, height: 12))
        }
        let g = graph, ser = series()
        switch section {
        case .cpu, .memory: drawOpt(ser[0].2, in: g, color: orange)
        case .internet:
            let m = max(ser.flatMap { $0.2.compactMap { $0 } }.max() ?? 1, 1)
            drawOpt(ser[0].2, in: NSRect(x: g.minX, y: g.midY, width: g.width, height: g.height / 2), color: blue, max: m)
            let w = g.width / CGFloat(n); orange.setFill()
            for (i, v) in ser[1].2.enumerated() { guard let v else { continue }
                let hh = CGFloat(v / m) * g.height / 2; NSRect(x: g.minX + CGFloat(i) * w, y: g.midY - hh, width: max(w - 1, 0.5), height: hh).fill() }
        case .ping:
            // ping bars on top, deviation bars underneath (like the ASUS game dashboard's two charts)
            let top = NSRect(x: g.minX, y: g.minY + g.height * 0.4, width: g.width, height: g.height * 0.6 - 4)
            let bot = NSRect(x: g.minX, y: g.minY, width: g.width, height: g.height * 0.4 - 4)
            drawOpt(ser[0].2, in: top, color: orange, max: max((ser[0].2.compactMap { $0 }.max() ?? 1) * 1.1, 10))
            drawOpt(ser[1].2, in: bot, color: blue, max: max((ser[1].2.compactMap { $0 }.max() ?? 1) * 1.1, 2))
        case .cores:
            let rowH = g.height / CGFloat(max(ser.count, 1))
            for (i, s) in ser.enumerated() {
                let row = NSRect(x: g.minX, y: g.maxY - rowH * CGFloat(i + 1) + 2, width: g.width, height: rowH - 4)
                NSColor.labelColor.withAlphaComponent(0.06).setFill(); row.fill()
                drawOpt(s.2, in: row, color: orange)
            }
        default: break
        }
        // crosshair + tooltip
        guard let x = hoverX else { return }
        let i = max(0, min(n - 1, Int((x - g.minX) / (g.width / CGFloat(n)))))
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSRect(x: x - 0.5, y: g.minY, width: 1, height: g.height + 6).fill()
        let tAt = Date().timeIntervalSince1970 - range + (Double(i) + 0.5) / Double(n) * range
        let f = DateFormatter(); f.dateFormat = "h:mm:ss a"
        var lines: [(NSColor?, String, String)] = [(nil, f.string(from: Date(timeIntervalSince1970: tAt)), "")]
        for s in ser { lines.append((s.1, s.0, s.2[i].map(s.3) ?? "–")) }
        let lh: CGFloat = 16, tw: CGFloat = 160, th = CGFloat(lines.count) * lh + 12
        var bx = x + 8; if bx + tw > bounds.maxX - 4 { bx = x - 8 - tw }
        let box = NSRect(x: bx, y: g.maxY - th + 4, width: tw, height: th)
        NSColor.black.withAlphaComponent(0.85).setFill(); NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).fill()
        for (k, l) in lines.enumerated() {
            let y = box.maxY - 8 - lh * CGFloat(k + 1) + 2
            if let c = l.0 {
                c.setFill(); NSBezierPath(ovalIn: NSRect(x: box.minX + 10, y: y + 3, width: 9, height: 9)).fill()
                drawText(text(l.1, color: .white), at: NSPoint(x: box.minX + 24, y: y))
                drawText(text(l.2, weight: .semibold, color: .white), at: NSPoint(x: box.maxX - 10, y: y), align: .right)
            } else { drawText(text(l.1, weight: .medium, color: .white), at: NSPoint(x: box.midX, y: y), align: .center) }
        }
    }

    func drawDevices() {
        drawText(text("\(s.devices.count) online", color: .secondaryLabelColor), at: NSPoint(x: bounds.maxX - 16, y: bounds.maxY - 30), align: .right)
        var y = bounds.maxY - 50
        let cols: [CGFloat] = [16, 196, 268, bounds.maxX - 16]
        drawText(text("Name", size: 10, color: .secondaryLabelColor), at: NSPoint(x: cols[0], y: y))
        drawText(text("Band", size: 10, color: .secondaryLabelColor), at: NSPoint(x: cols[1], y: y))
        drawText(text("IP", size: 10, color: .secondaryLabelColor), at: NSPoint(x: cols[2], y: y))
        drawText(text("Signal", size: 10, color: .secondaryLabelColor), at: NSPoint(x: cols[3], y: y), align: .right)
        for d in deviceRows {
            y -= Flyout.rowH
            drawText(text(d.name, size: 11), at: NSPoint(x: cols[0], y: y), maxWidth: cols[1] - cols[0] - 8)
            drawText(text(d.band, size: 11, color: .secondaryLabelColor), at: NSPoint(x: cols[1], y: y))
            drawText(text(d.ip.replacingOccurrences(of: "192.168.1.", with: "…"), size: 11, color: .secondaryLabelColor), at: NSPoint(x: cols[2], y: y))
            drawText(text(d.rssi.map { "\($0) dBm" } ?? "–", size: 11, color: signalColor(d.rssi)), at: NSPoint(x: cols[3], y: y), align: .right)
        }
    }
}

// MARK: local ping (runs on this Mac, not the router)
final class Pinger {
    private var last: Double?
    private var results: [Bool] = []          // last 30 replies, for loss %
    private var busy = false
    var onResult: ((Double, Double, Double) -> Void)?   // ping, deviation, loss%

    func tick() {
        guard !busy else { return }
        busy = true
        DispatchQueue.global(qos: .utility).async {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/sbin/ping")
            p.arguments = ["-c", "1", "-n", "-W", "1500", pingTarget]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
            var v: Double = -1
            if (try? p.run()) != nil {
                p.waitUntilExit()
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if let r = out.range(of: #"time=([0-9.]+)"#, options: .regularExpression) { v = Double(out[r].dropFirst(5)) ?? -1 }
            }
            DispatchQueue.main.async {
                self.busy = false
                self.results.append(v >= 0); if self.results.count > 30 { self.results.removeFirst() }
                let dev: Double = (v >= 0 && self.last != nil) ? abs(v - self.last!) : -1
                if v >= 0 { self.last = v }
                let loss = 100 * Double(self.results.filter { !$0 }.count) / Double(self.results.count)
                self.onResult?(v, dev, loss)
            }
        }
    }
}

// MARK: app
final class App: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: 46)
    let panel = Panel(frame: NSRect(x: 0, y: 0, width: 290, height: Panel.totalHeight))
    let flyoutView = Flyout(frame: NSRect(origin: .zero, size: Flyout.graphSize))
    lazy var popup = makeWindow(panel)
    lazy var flyout = makeWindow(flyoutView)
    let pinger = Pinger()
    var client: RouterClient?
    var setup: SetupWindow?
    var prevCPU: [String: (Double, Double)] = [:], prevNet: (Double, Double, Date)?
    var h = History.load(), s = Sample(), failed = false, lastSave = Date()
    var pollCount = 0
    var clickMonitor: Any?

    func makeWindow(_ content: NSView) -> NSPanel {
        let p = NSPanel(contentRect: content.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .popUpMenu; p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.hidesOnDeactivate = false; p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.acceptsMouseMovedEvents = true
        let fx = NSVisualEffectView(frame: content.frame)
        fx.material = .popover; fx.state = .active; fx.blendingMode = .behindWindow
        fx.wantsLayer = true; fx.layer?.cornerRadius = 12; fx.layer?.masksToBounds = true
        fx.autoresizingMask = [.width, .height]; content.autoresizingMask = [.width, .height]
        fx.addSubview(content); p.contentView = fx
        return p
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        item.autosaveName = "RouterStats"
        item.isVisible = true
        if let b = item.button { b.target = self; b.action = #selector(clicked); b.sendAction(on: [.leftMouseUp, .rightMouseUp]) }
        panel.onHover = { [weak self] sec in self?.showFlyout(sec) }
        pinger.onResult = { [weak self] p, d, l in self?.s.ping = p; self?.s.dev = d; self?.s.loss = l }
        renderIcon()
        if let cfg = Config.current, let pw = Keychain.read(cfg.keychainAccount) {
            client = RouterClient(config: cfg, password: pw); poll()
        } else { openSettings() }
        if CommandLine.arguments.contains("--snapshot") { snapshotSoon() }
        let t = Timer(timeInterval: 2, repeats: true) { _ in self.poll() }
        RunLoop.main.add(t, forMode: .common)
    }

    @objc func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            closePopup()
            let m = NSMenu()
            let o = NSMenuItem(title: "Open Network Map", action: #selector(openMap), keyEquivalent: ""); o.target = self
            m.addItem(o)
            let st = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","); st.target = self
            m.addItem(st); m.addItem(.separator())
            m.addItem(NSMenuItem(title: "Quit RouterStats", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))
            item.menu = m; item.button?.performClick(nil); item.menu = nil
        } else if client == nil { openSettings() }
        else if popup.isVisible { closePopup() } else { openPopup() }
    }

    @objc func openSettings() {
        closePopup()
        setup = SetupWindow(existing: Config.current) { [weak self] cfg, pw in
            guard let self else { return }
            self.client = RouterClient(config: cfg, password: pw)
            self.prevCPU = [:]; self.prevNet = nil; self.failed = false
            self.poll()
        }
        setup?.show()
    }

    func openPopup() {
        guard let b = item.button, let w = b.window else { return }
        let r = w.convertToScreen(b.convert(b.bounds, to: nil))
        var x = r.midX - popup.frame.width / 2
        if let sf = w.screen?.visibleFrame { x = min(max(x, sf.minX + 6), sf.maxX - popup.frame.width - 6) }
        popup.setFrameOrigin(NSPoint(x: x, y: r.minY - popup.frame.height - 4))
        panel.needsDisplay = true
        popup.orderFrontRegardless()
        b.highlight(true)
        // close on any click outside our windows (like a menu)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.closePopup() }
    }

    func closePopup() {
        popup.orderOut(nil); flyout.orderOut(nil); panel.hovered = nil
        item.button?.highlight(false)
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    func showFlyout(_ sec: Section?) {
        // Like iStat: the flyout follows the hovered section and stays put while the pointer travels into it.
        guard let sec, popup.isVisible else { return }
        guard flyoutSections.contains(sec) else { flyout.orderOut(nil); return }
        flyoutView.section = sec; flyoutView.h = h; flyoutView.s = s
        let size = flyoutView.preferredSize()
        var x = popup.frame.minX - size.width
        if let sf = popup.screen?.visibleFrame, x < sf.minX { x = popup.frame.maxX }
        // line the flyout's top up with the hovered card's top (like iStat), keeping it on screen
        let cardTop = popup.frame.minY + (panel.rects[sec]?.maxY ?? panel.bounds.maxY) + 8
        var y = min(cardTop, popup.frame.maxY) - size.height
        if let sf = popup.screen?.visibleFrame { y = max(y, sf.minY + 6) }
        flyout.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        flyout.orderFrontRegardless()
    }

    func snapshotSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            func save(_ v: NSView, _ path: String) {
                v.wantsLayer = true; v.layer?.backgroundColor = NSColor(white: 0.17, alpha: 1).cgColor
                NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
                    let r = v.bitmapImageRepForCachingDisplay(in: v.bounds)!; v.cacheDisplay(in: v.bounds, to: r)
                    try? r.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
                }
            }
            if CommandLine.arguments.contains("--demo") {   // sample values for README screenshots
                self.s.publicIP = "203.0.113.24"
                let names = ["iPhone", "MacBook-Pro", "Pixel-8", "Apple-Watch", "Living-Room-TV", "Thermostat", "Doorbell", "Garage-Door",
                             "Smart-Plug", "Air-Monitor", "Printer", "Kitchen-Speaker", "Camera-Front", "Camera-Back", "Robot-Vacuum",
                             "Light-Strip", "Raspberry-Pi", "Desk-Lamp", "Smart-Plug-2", "Sprinkler", "Weather-Station", "Fridge", "Mac-Studio", "NAS"]
                for i in self.s.devices.indices {
                    self.s.devices[i].name = names[i % names.count]
                    self.s.devices[i].ip = "192.168.1.\(20 + i)"
                }
            }
            self.panel.h = self.h; self.panel.s = self.s
            self.panel.appearance = NSAppearance(named: .darkAqua); self.panel.hovered = .ping
            save(self.panel, "/tmp/rs-panel.png")
            for sec in [Section.ping, .devices, .cpu, .internet, .cores] {
                self.flyoutView.section = sec; self.flyoutView.h = self.h; self.flyoutView.s = self.s
                self.flyoutView.appearance = NSAppearance(named: .darkAqua)
                self.flyoutView.setFrameSize(self.flyoutView.preferredSize())
                self.flyoutView.rangeIdx = 0; self.flyoutView.hoverX = sec == .devices ? nil : 300
                save(self.flyoutView, "/tmp/rs-flyout-\(sec).png")
            }
            let sw = SetupWindow(existing: nil) { _, _ in }
            if let v = sw.window?.contentView { v.layoutSubtreeIfNeeded(); v.appearance = NSAppearance(named: .darkAqua); save(v, "/tmp/rs-setup.png") }
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ n: Notification) { h.save() }

    @objc func openMap() {
        guard let u = Config.current?.baseURL?.appendingPathComponent("index.asp") else { return }
        NSWorkspace.shared.open(u)
    }

    func renderIcon() {
        let bad = failed || !s.online
        let size = NSSize(width: 46, height: 22)
        let img = NSImage(size: size, flipped: false) { _ in
            // CPU history graph with frame
            let g = NSRect(x: 1, y: 3, width: 26, height: 16)
            (bad ? NSColor.systemRed : NSColor.labelColor.withAlphaComponent(0.25)).setStroke()
            let f = NSBezierPath(rect: g.insetBy(dx: -0.5, dy: -0.5)); f.lineWidth = 1; f.stroke()
            let n = Int(g.width)
            let tail = Array(self.h.cpu.suffix(n)), vals = Array(repeating: 0.0, count: n - tail.count) + tail
            drawBars(vals, in: g, color: bad ? .systemRed : orange)
            // RAM pie
            drawPie(center: NSPoint(x: 37, y: 11), radius: 7.5, frac: self.s.mem, color: bad ? .systemRed : orange)
            return true
        }
        item.button?.image = img
        item.button?.toolTip = client == nil ? "RouterStats: click to set up" : failed ? "Router unreachable" : !s.online ? "Internet is down"
            : String(format: "Router CPU %.0f%%  RAM %.0f%%  Ping %@", s.cpu, s.mem * 100, ms(s.ping))
    }

    // Fast stats every poll; device list, ports and firmware every 30 s. The router needs ";" sent as %3B.
    func fetch(slow: Bool) async throws -> [String: Any] {
        var hooks = ["cpu_usage(appobj)", "memory_usage(appobj)", "netdev(appobj)", "uptime()", "get_cpu_temperature()",
                     "nvram_get(link_internet)", "nvram_get(wan0_realip_ip)"]
        if slow { hooks += ["get_clientlist()", "get_allclientlist()", "get_wan_lan_status()",
                            "nvram_get(firmver)", "nvram_get(buildno)", "nvram_get(extendno)", "nvram_get(webs_state_flag)"] }
        guard let client else { throw RouterError.badLogin }
        return try await client.get(hooks)
    }

    func poll() {
        guard client != nil else { return }
        pinger.tick()
        let slow = pollCount % 15 == 0; pollCount += 1
        Task { @MainActor in
            do { update(try await fetch(slow: slow)); failed = false } catch { failed = true }
            renderIcon(); panel.h = h; panel.s = s; panel.needsDisplay = true
            if flyout.isVisible { flyoutView.h = h; flyoutView.s = s; flyoutView.needsDisplay = true }
        }
    }

    @MainActor func update(_ d: [String: Any]) {
        guard let c = d["cpu_usage"] as? [String: String], let m = d["memory_usage"] as? [String: String] else { return }
        let cores = Set(c.keys.compactMap { $0.split(separator: "_").first.map(String.init) })
            .sorted { Int($0.dropFirst(3)) ?? 0 < Int($1.dropFirst(3)) ?? 0 }
        var pcts: [Double] = []
        for k in cores {
            let u = Double(c["\(k)_usage"] ?? "0") ?? 0, t = Double(c["\(k)_total"] ?? "0") ?? 0
            if let (pu, pt) = prevCPU[k], t > pt { pcts.append(100 * (u - pu) / (t - pt)) }
            else { pcts.append(t > 0 ? 100 * u / t : 0) }
            prevCPU[k] = (u, t)
        }
        s.cores = pcts
        s.cpu = pcts.reduce(0, +) / Double(max(pcts.count, 1))
        s.memTotal = Double(m["mem_total"] ?? "1") ?? 1
        s.memUsed = Double(m["mem_used"] ?? "0") ?? 0
        if let n = d["netdev"] as? [String: String] {
            let rx = Double(UInt64((n["INTERNET_rx"] ?? "0x0").dropFirst(2), radix: 16) ?? 0)
            let tx = Double(UInt64((n["INTERNET_tx"] ?? "0x0").dropFirst(2), radix: 16) ?? 0)
            if let (prx, ptx, pt) = prevNet {
                let dt = max(Date().timeIntervalSince(pt), 0.5)
                s.down = max(0, rx - prx) / dt; s.up = max(0, tx - ptx) / dt
            }
            prevNet = (rx, tx, Date())
        }
        if let u = d["uptime"] as? String, let r = u.range(of: #"\((\d+) secs"#, options: .regularExpression) {
            s.uptime = Int(u[r].dropFirst().split(separator: " ").first ?? "0") ?? 0
        }
        if let t = d["get_cpu_temperature"] as? Double { s.temp = t } else if let t = d["get_cpu_temperature"] as? NSNumber { s.temp = t.doubleValue }
        if let l = d["link_internet"] as? String { s.online = l == "2" }
        if let ip = d["wan0_realip_ip"] as? String, !ip.isEmpty { s.publicIP = ip }

        // slow fields
        if let names = d["get_clientlist"] as? [String: Any], let all = d["get_allclientlist"] as? [String: Any] {
            var band: [String: String] = [:], rssi: [String: Int] = [:]
            for (_, node) in all {
                guard let bands = node as? [String: Any] else { continue }
                for (b, macs) in bands {
                    let label = b.hasPrefix("2G") ? "2.4 GHz" : b.hasPrefix("5G") ? "5 GHz" : b.hasPrefix("6G") ? "6 GHz" : "Wired"
                    for (mac, info) in (macs as? [String: Any]) ?? [:] {
                        band[mac] = label
                        if let r = (info as? [String: Any])?["rssi"] as? String, let v = Int(r), v != 0 { rssi[mac] = v }
                    }
                }
            }
            s.devices = band.keys.map { mac in
                let info = names[mac] as? [String: Any] ?? [:]
                let nick = info["nickName"] as? String ?? "", nm = info["name"] as? String ?? ""
                let vendor = info["vendor"] as? String ?? ""
                let label = !nick.isEmpty ? nick : !nm.isEmpty ? nm : !vendor.isEmpty ? vendor : mac
                return Device(name: label, ip: info["ip"] as? String ?? "", band: band[mac]!, rssi: rssi[mac], wired: band[mac] == "Wired")
            }
        }
        if let ws = d["get_wan_lan_status"] as? [String: Any], let ps = ws["portSpeed"] as? [String: String] {
            let speed = ["X": "–", "M": "100M", "G": "1G", "Q": "2.5G", "F": "5G", "T": "10G"]
            s.ports = ps.sorted { a, b in
                let wa = a.key.hasPrefix("WAN"), wb = b.key.hasPrefix("WAN")
                return wa != wb ? wa : a.key.localizedStandardCompare(b.key) == .orderedAscending
            }.map { ($0.key.replacingOccurrences(of: "WAN 0", with: "WAN").replacingOccurrences(of: "LAN ", with: "LAN"), speed[$0.value] ?? $0.value) }
        }
        if let fv = d["firmver"] as? String, let bn = d["buildno"] as? String {
            let ext = (d["extendno"] as? String ?? "").split(separator: "-").first.map(String.init) ?? ""
            s.firmware = "\(fv).\(bn)" + (ext.isEmpty ? "" : "_\(ext)")
            s.update = ["1", "2"].contains(d["webs_state_flag"] as? String ?? "0")
        }
        h.push(s)
        if Date().timeIntervalSince(lastSave) > 60 { h.save(); lastSave = Date() }
    }
}

if CommandLine.arguments.contains("--selftest-history") {
    var h = History(); var smp = Sample(); smp.cores = [10, 20]
    let start = 1_700_000_000.0, step = 2.0, total = Int(9 * 86400 / step)
    for k in 0..<total { smp.cpu = Double(k % 100); smp.ping = k % 10 == 0 ? -1 : 5; h.push(smp, at: start + Double(k) * step) }
    let now = start + Double(total - 1) * step
    let oldest = now - h.t[0], rawStart = h.t[h.compacted]
    let sorted = zip(h.t, h.t.dropFirst()).allSatisfy { $0 < $1 }
    let lens = Set([h.t.count, h.cpu.count, h.mem.count, h.ping.count, h.devices.count] + h.cores.map(\.count))
    let minuteGaps = zip(h.t[..<h.compacted], h.t[1..<max(h.compacted, 1)]).allSatisfy { $1 - $0 >= 59.9 }
    print(String(format: "points=%d compacted=%d oldest=%.2f days rawFrom=%.2f h ago sorted=%@ sameLengths=%@ minuteSpacing=%@ pingAvg=%.1f",
                 h.t.count, h.compacted, oldest / 86400, (now - rawStart) / 3600, "\(sorted)", "\(lens.count == 1)", "\(minuteGaps)", h.ping[0]))
    let b = h.buckets(h.cpu, n: 90, range: 604800, now: now)
    print("7-day buckets with data:", b.compactMap { $0 }.count, "/ 90")
    let data = try! JSONEncoder().encode(h); print("json MB:", Double(data.count) / 1e6)
    let r = try! JSONDecoder().decode(History.self, from: data); print("reload points:", r.t.count, "compacted:", r.compacted)
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--configure") {
    let a = Array(CommandLine.arguments.dropFirst(i + 1))
    guard a.count >= 2 else { FileHandle.standardError.write("usage: RouterStats --configure <address> <username> [pingTarget] < password\n".data(using: .utf8)!); exit(2) }
    let pw = (readLine(strippingNewline: true) ?? "")
    let cfg = Config(address: a[0], username: a[1], pingTarget: a.count > 2 ? a[2] : "8.8.8.8")
    let sem = DispatchSemaphore(value: 0); var err: Error?
    Task { do { try await RouterClient(config: cfg, password: pw).login() } catch { err = error }; sem.signal() }
    sem.wait()
    if let err { FileHandle.standardError.write("Login failed: \((err as? LocalizedError)?.errorDescription ?? err.localizedDescription)\n".data(using: .utf8)!); exit(1) }
    guard Keychain.write(pw, account: cfg.keychainAccount) else { FileHandle.standardError.write("Keychain write failed\n".data(using: .utf8)!); exit(1) }
    cfg.save(); print("Saved. Login OK for \(cfg.username) at \(cfg.address)."); exit(0)
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
