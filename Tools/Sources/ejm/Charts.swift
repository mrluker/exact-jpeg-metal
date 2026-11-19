import Foundation

// README charts as static SVG, regenerated from committed results by `ejm charts [results] [docs/images]` (no
// Python needed). One SVG per chart, drawn on a white background. Under each chart title a badge says which way is
// better; every numeric axis is linear and labelled with its unit, separately from its tick numbers; every value
// carries its unit. Each bar is named inside it at the left (white bold) and, where the bar is long enough, its value
// and comparison sit inside it at the right; otherwise the text goes just after the bar's end in dark text.
// Fills: one per implementation, the same in every chart (see `Fill`).
// Before a chart is saved its text is checked (SVGCanvas.finish): each label's bounding box is estimated from a
// conservative glyph width table, and the chart is refused (not written; `charts` exits 1, naming the chart and the
// labels) when two labels overlap, a label overlaps a bar or badge it is not inside, leaves the canvas or its bar,
// or its colour has too little contrast with what is behind it (WCAG relative luminance: at least 5:1 for text on
// a fill, 4.5:1 for text on white).

enum Ink {
    static let bg = "#ffffff", text = "#241f31", text2 = "#5e5c64", grid = "#deddda", base = "#9a9996"
    static let white = "#ffffff"
    /// the direction badge: highlighter yellow with a dark border and dark bold text (no data series is yellow)
    static let badge = "#f6d32d", badgeInk = "#1d1d1b"
}
/// one fill per implementation, the same in every chart
enum Fill {
    static let ours = "#1a5fb4"          // exact-jpeg-metal
    static let oursGPU = "#0d3b70"       // exact-jpeg-metal, GPU busy time (small-image chart only)
    static let turbo1 = "#6b6965"        // libjpeg-turbo, 1 CPU core
    static let turboAll = "#3d3846"      // libjpeg-turbo, all CPU cores
    static let imageio = "#277a4c"       // Apple ImageIO
    static let videotoolbox = "#613583"  // VideoToolbox (Apple hardware decoder)
}

/// WCAG 2 relative luminance of "#rrggbb" (nil if the colour is not in that form)
func relativeLuminance(_ hex: String) -> Double? {
    let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
    func ch(_ c: UInt32) -> Double { let s = Double(c) / 255; return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
    return 0.2126 * ch(v >> 16 & 255) + 0.7152 * ch(v >> 8 & 255) + 0.0722 * ch(v & 255)
}
func contrastRatio(_ a: String, _ b: String) -> Double? {
    guard let x = relativeLuminance(a), let y = relativeLuminance(b) else { return nil }
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
}

/// Estimated width of a label in px: per-character widths in em, wider than system-ui / Helvetica / Arial
/// actually draw them (conservative, so a label that passes the overlap check has room in any of those fonts).
func textWidth(_ s: String, size: Double, bold: Bool) -> Double {
    var em = 0.0
    for ch in s {
        switch ch {
        case "i", "j", "l", "I", "!", ".", ",", ":", ";", "'", "|", " ": em += 0.32
        case "f", "t", "r", "(", ")", "[", "]", "-", "/", "\u{00B7}": em += 0.42
        case "m", "w", "M", "W", "%", "@", "\u{2191}", "\u{2193}": em += 0.92
        case "A"..."Z": em += 0.74
        case "0"..."9": em += 0.62
        default: em += 0.6
        }
    }
    return em * size * (bold ? 1.08 : 1.0)
}

/// greedy word wrap to an estimated width
func wrapWidth(_ s: String, _ maxW: Double, size: Double, bold: Bool = false) -> [String] {
    var lines: [String] = [], line = ""
    for w in s.split(separator: " ") {
        let cand = line.isEmpty ? String(w) : line + " " + w
        if !line.isEmpty && textWidth(cand, size: size, bold: bold) > maxW { lines.append(line); line = String(w) } else { line = cand }
    }
    if !line.isEmpty { lines.append(line) }
    return lines
}

/// XML-escaped, non-ASCII as numeric references (the file stays ASCII whatever serves it)
private func esc(_ s: String) -> String {
    var out = ""
    for u in s.unicodeScalars {
        switch u {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "'": out += "&#39;"
        default: out += u.isASCII ? String(u) : "&#\(u.value);"
        }
    }
    return out
}
private func n(_ v: Double) -> String { let s = String(format: "%.1f", v); return s.hasSuffix(".0") ? String(s.dropLast(2)) : s }

/// An SVG being drawn, with every label's estimated box and every filled shape kept for the checks in `finish`.
final class SVGCanvas {
    struct Box { let label: String; let x0: Double, y0: Double, x1: Double, y1: Double; let onFill: Bool }
    let name: String, width: Double
    private var body = ""
    private var boxes: [Box] = [], fills: [Box] = []
    private var problems: [String] = []
    init(_ name: String, width: Double) { self.name = name; self.width = width }

    func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, stroke: String) {
        body += "<line x1='\(n(x1))' y1='\(n(y1))' x2='\(n(x2))' y2='\(n(y2))' stroke='\(stroke)' stroke-width='1'/>"
    }
    /// a filled shape that text may sit inside (with bg = its fill) but must not otherwise overlap
    func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, rx: Double = 0, fill: String, stroke: String? = nil, label: String) {
        body += "<rect x='\(n(x))' y='\(n(y))' width='\(n(w))' height='\(n(h))'\(rx > 0 ? " rx='\(n(rx))'" : "") fill='\(fill)'\(stroke.map { " stroke='\($0)' stroke-width='1.5'" } ?? "")/>"
        fills.append(Box(label: label, x0: x, y0: y, x1: x + w, y1: y + h, onFill: true))
    }
    /// an outlined shape (no checks: text is meant to sit on it)
    func outline(_ x: Double, _ y: Double, _ w: Double, _ h: Double, rx: Double, stroke: String) {
        body += "<rect x='\(n(x))' y='\(n(y))' width='\(n(w))' height='\(n(h))' rx='\(n(rx))' fill='none' stroke='\(stroke)'/>"
    }
    /// horizontal bar, square at the baseline, 4 px rounded data end
    func bar(_ x: Double, _ y: Double, _ w: Double, _ h: Double, fill: String, title: String) {
        let r = min(4.0, w / 2)
        body += "<path d='M\(n(x)),\(n(y)) h\(n(w - r)) a\(n(r)),\(n(r)) 0 0 1 \(n(r)),\(n(r)) v\(n(h - 2 * r)) a\(n(r)),\(n(r)) 0 0 1 -\(n(r)),\(n(r)) h-\(n(w - r)) z' fill='\(fill)'><title>\(esc(title))</title></path>"
        fills.append(Box(label: "bar " + title, x0: x, y0: y, x1: x + w, y1: y + h, onFill: true))
    }
    /// a label; y is its baseline. `bg` is the colour behind it (a fill when it sits inside a shape, then `within`
    /// is that shape and the label must fit inside it)
    func text(_ s: String, x: Double, y: Double, size: Double, bold: Bool = false, fill: String = Ink.text,
              anchor: String = "start", bg: String = Ink.bg, within: (x0: Double, x1: Double, y0: Double, y1: Double)? = nil,
              boldPrefix: String? = nil) {
        // with boldPrefix: "<prefix in bold> <s>" as one label
        let w = textWidth(s, size: size, bold: bold) + (boldPrefix.map { textWidth($0 + " ", size: size, bold: true) } ?? 0)
        let x0 = anchor == "middle" ? x - w / 2 : anchor == "end" ? x - w : x
        let b = Box(label: (boldPrefix.map { $0 + " " } ?? "") + s, x0: x0, y0: y - size * 0.8, x1: x0 + w, y1: y + size * 0.25, onFill: within != nil)
        boxes.append(b)
        let need = bg.lowercased() == Ink.bg ? 4.5 : 5.0
        if let cr = contrastRatio(fill, bg) {
            if cr < need { problems.append(String(format: "contrast %.2f:1, below %.1f:1, for \"%@\" (%@ on %@)", cr, need, s, fill, bg)) }
        } else { problems.append("colour not checkable for \"\(s)\" (\(fill) on \(bg))") }
        if let r = within, b.x0 < r.x0 || b.x1 > r.x1 || b.y0 < r.y0 || b.y1 > r.y1 { problems.append("\"\(s)\" does not fit inside its shape") }
        body += "<text x='\(n(x))' y='\(n(y))' font-size='\(n(size))'\(bold ? " font-weight='700'" : "") fill='\(fill)'\(anchor == "start" ? "" : " text-anchor='\(anchor)'")>\(boldPrefix.map { "<tspan font-weight='700'>\(esc($0))</tspan> " } ?? "")\(esc(s))</text>"
    }
    /// The SVG, or nil when a check failed (each problem printed with the chart's name).
    func finish(height: Double, aria: String) -> String? {
        func hit(_ a: Box, _ b: Box) -> Bool { a.x0 < b.x1 && b.x0 < a.x1 && a.y0 < b.y1 && b.y0 < a.y1 }
        for b in boxes where b.x0 < 0 || b.x1 > width || b.y0 < 0 || b.y1 > height { problems.append("\"\(b.label)\" leaves the canvas") }
        for i in boxes.indices { for j in boxes.indices where j > i && hit(boxes[i], boxes[j]) {
            problems.append("\"\(boxes[i].label)\" overlaps \"\(boxes[j].label)\"")
        } }
        // a label on white must not touch any shape; one inside a shape must not touch another shape
        for b in boxes { for f in fills where hit(b, f) {
            if !b.onFill || !(b.x0 >= f.x0 && b.x1 <= f.x1 && b.y0 >= f.y0 && b.y1 <= f.y1) { problems.append("\"\(b.label)\" overlaps \(f.label)") }
        } }
        if !problems.isEmpty { for p in problems { print("chart \(name): \(p)") }; return nil }
        return "<svg xmlns='http://www.w3.org/2000/svg' width='\(Int(width))' height='\(Int(height.rounded(.up)))' viewBox='0 0 \(Int(width)) \(Int(height.rounded(.up)))' font-family='system-ui, -apple-system, Segoe UI, Helvetica, Arial, sans-serif' role='img' aria-label='\(esc(aria))'><rect width='100%' height='100%' fill='\(Ink.bg)'/>" + body + "</svg>\n"
    }
}

/// "Higher is better" / "Lower is better" pill (highlighter yellow); returns its bottom
func badge(_ c: SVGCanvas, x: Double, y: Double, higherIsBetter: Bool) -> Double {
    let s = higherIsBetter ? "\u{2191} Higher is better" : "\u{2193} Lower is better"
    let h = 24.0, w = textWidth(s, size: 12, bold: true) + 24
    c.rect(x, y, w, h, rx: h / 2, fill: Ink.badge, stroke: Ink.badgeInk, label: "the badge")
    c.text(s, x: x + 12, y: y + 16.3, size: 12, bold: true, fill: Ink.badgeInk, bg: Ink.badge, within: (x, x + w, y, y + h))
    return y + h
}

// ---- horizontal bars ----

struct Bar {
    let name: String; let value: Double; let valueText: String; var comparison: String? = nil; let fill: String
    var fullValue: String { valueText + (comparison.map { " \u{00B7} " + $0 } ?? "") }
}
private let barH = 22.0, barGap = 8.0, barPad = 8.0, barFont = 12.0

private struct BarLayout { let w: Double; let nameInside: Bool; let valueInside: Bool; let right: Double }
private func layoutBar(_ b: Bar, left: Double, plotW: Double, top: Double) -> BarLayout {
    let w = max(b.value / top * plotW, 2)
    let nw = textWidth(b.name, size: barFont, bold: true), vw = textWidth(b.fullValue, size: barFont, bold: false)
    let nameIn = w >= nw + 2 * barPad
    let valIn = nameIn && w >= barPad + nw + 16 + vw + barPad
    let right = valIn ? left + w : nameIn ? left + w + 6 + vw : left + w + 6 + textWidth(b.name + " ", size: barFont, bold: true) + vw
    return BarLayout(w: w, nameInside: nameIn, valueInside: valIn, right: right)
}

func niceStep(_ maxV: Double) -> Double {
    let raw = maxV / 4
    let mag = pow(10, floor(log10(raw)))
    for m in [1.0, 2.0, 2.5, 5.0, 10.0] where m * mag >= raw { return m * mag }
    return 10 * mag
}

/// A linear axis from 0 whose top leaves room for every label drawn after its bar's end.
func fitScale(_ bars: [Bar], plotW: Double) -> (top: Double, step: Double) {
    var t = max(bars.map(\.value).max() ?? 1, 1e-9)
    for _ in 0..<80 {
        let step = niceStep(t), top = (t / step - 1e-9).rounded(.up) * step
        if bars.allSatisfy({ layoutBar($0, left: 0, plotW: plotW, top: top).right <= plotW }) { return (top, step) }
        t = top * 1.08
    }
    let step = niceStep(t)
    return ((t / step).rounded(.up) * step, step)
}

func tickText(_ v: Double, _ step: Double) -> String {
    step >= 1 || v == 0 ? String(format: "%.0f", v) : step >= 0.1 ? String(format: "%.1f", v) : String(format: "%.2f", v)
}

/// One block of bars (slots may be empty) with its gridlines, tick numbers and axis label; returns its bottom.
@discardableResult
func drawBars(_ c: SVGCanvas, _ slots: [Bar?], left: Double, plotW: Double, y0: Double, top: Double, step: Double,
              axisLabel: String, tick: (Double) -> String) -> Double {
    let height = Double(slots.count) * (barH + barGap) - barGap
    var v = 0.0
    while v <= top + step * 1e-6 {
        let x = left + v / top * plotW
        c.line(x, y0 - 4, x, y0 + height + 4, stroke: v == 0 ? Ink.base : Ink.grid)
        c.text(tick(v), x: x, y: y0 + height + 19, size: 11, fill: Ink.text2,
               anchor: v == 0 ? "start" : abs(v - top) < step * 1e-6 ? "end" : "middle")
        v += step
    }
    c.text(axisLabel, x: left + plotW / 2, y: y0 + height + 37, size: 11.5, fill: Ink.text2, anchor: "middle")
    for (k, b) in slots.enumerated() {
        guard let b else { continue }
        let by = y0 + Double(k) * (barH + barGap), L = layoutBar(b, left: left, plotW: plotW, top: top)
        c.bar(left, by, L.w, barH, fill: b.fill, title: "\(b.name): \(b.fullValue)")
        let ty = by + barH / 2 + 4.3, inside = (x0: left, x1: left + L.w, y0: by, y1: by + barH)
        if L.nameInside {
            c.text(b.name, x: left + barPad, y: ty, size: barFont, bold: true, fill: Ink.white, bg: b.fill, within: inside)
            if L.valueInside {
                c.text(b.fullValue, x: left + L.w - barPad, y: ty, size: barFont, fill: Ink.white, anchor: "end", bg: b.fill, within: inside)
            } else { c.text(b.fullValue, x: left + L.w + 6, y: ty, size: barFont) }
        } else {
            c.text(b.fullValue, x: left + L.w + 6, y: ty, size: barFont, boldPrefix: b.name)
        }
    }
    return y0 + height + 44
}

// ---- grid charts: one column per machine (each machine against itself), one row per task ----
// A row shares one linear axis across the machines in it.

struct ColumnHead { let name: String; let spec: String }
struct BarRow { let title: String; var notes: [String]? = nil; let cells: [[Bar?]] }   // cells[machine][slot]

/// title, badge, subtitle lines; returns the y below them
private func header(_ c: SVGCanvas, x: Double, y: Double, width: Double, title: String, size: Double = 20,
                    higherIsBetter: Bool, subtitle: [String]) -> Double {
    var y = y
    for (i, l) in wrapWidth(title, width, size: size, bold: true).enumerated() {
        if i > 0 { y += size * 1.25 }
        c.text(l, x: x, y: y, size: size, bold: true)
    }
    y = badge(c, x: x, y: y + 12, higherIsBetter: higherIsBetter)
    for s in subtitle { for l in wrapWidth(s, width, size: 12.5) { y += 18; c.text(l, x: x, y: y, size: 12.5, fill: Ink.text2) } }
    return y
}

func gridChart(_ name: String, title: String, higherIsBetter: Bool, subtitle: [String], columns: [ColumnHead],
               rows: [BarRow], axisLabel: String, notes: [String]) -> String? {
    let cols = max(columns.count, 1), W = cols == 1 ? 760.0 : 1200.0, gap = 44.0
    let colW = (W - 40 - gap * Double(cols - 1)) / Double(cols)
    func cx(_ k: Int) -> Double { 20 + Double(k) * (colW + gap) }
    let c = SVGCanvas(name, width: W)
    var y = header(c, x: 20, y: 34, width: W - 40, title: title, higherIsBetter: higherIsBetter, subtitle: subtitle) + 12
    var hy = y
    for (k, m) in columns.enumerated() {
        var yy = y + 26
        c.text(m.name, x: cx(k), y: yy, size: 20, bold: true)
        for l in m.spec.components(separatedBy: "\n").flatMap({ wrapWidth($0, colW, size: 12) }) {
            yy += 17; c.text(l, x: cx(k), y: yy, size: 12, fill: Ink.text2)
        }
        hy = max(hy, yy)
    }
    y = hy
    for r in rows {
        y += 38
        let tl = wrapWidth(r.title, colW, size: 14, bold: true)
        for k in 0..<cols { for (i, l) in tl.enumerated() { c.text(l, x: cx(k), y: y + Double(i) * 18, size: 14, bold: true) } }
        y += Double(tl.count - 1) * 18
        if let notes = r.notes {
            let nl = (0..<cols).map { k in k < notes.count ? wrapWidth(notes[k], colW, size: 12, bold: true) : [] }
            for k in 0..<cols { for (i, l) in nl[k].enumerated() { c.text(l, x: cx(k), y: y + 18 + Double(i) * 16, size: 12, bold: true, fill: Ink.text2) } }
            y += 18 + Double(max((nl.map(\.count).max() ?? 1) - 1, 0)) * 16
        }
        let y0 = y + 16
        // slots with a bar in some column (a task without, say, a batch variant leaves no gap)
        let nSlots = r.cells.map(\.count).max() ?? 0
        let shown = (0..<nSlots).filter { s in r.cells.contains { s < $0.count && $0[s] != nil } }
        let per = r.cells.map { col in shown.map { $0 < col.count ? col[$0] : nil } }
        let (top, step) = fitScale(per.flatMap { $0.compactMap { $0 } }, plotW: colW)
        var yEnd = y0
        for k in 0..<min(cols, per.count) {
            yEnd = max(yEnd, drawBars(c, per[k], left: cx(k), plotW: colW, y0: y0, top: top, step: step, axisLabel: axisLabel,
                                      tick: { tickText($0, step) }))
        }
        y = yEnd
    }
    y += 4
    for s in notes { for l in wrapWidth(s, W - 40, size: 12) { y += 17; c.text(l, x: 20, y: y, size: 12, fill: Ink.text2) } }
    return c.finish(height: y + 18, aria: title)
}

/// stat tiles (not a chart: the job is a few headline numbers)
func tilesChart(_ name: String, title: String, subtitle: [String], tiles: [(String, String, String)]) -> String? {
    let W = 820.0, c = SVGCanvas(name, width: W)
    var y = 34.0
    c.text(title, x: 20, y: y, size: 20, bold: true)
    for s in subtitle { for l in wrapWidth(s, W - 40, size: 12.5) { y += 18; c.text(l, x: 20, y: y, size: 12.5, fill: Ink.text2) } }
    y += 18
    let cols = 3, tw = (W - 40 - Double(cols - 1) * 12) / Double(cols), th = 94.0
    for (i, tile) in tiles.enumerated() {
        let x = 20 + Double(i % cols) * (tw + 12), ty = y + Double(i / cols) * (th + 12)
        let box = (x0: x, x1: x + tw, y0: ty, y1: ty + th)
        c.outline(x, ty, tw, th, rx: 8, stroke: Ink.grid)
        c.text(tile.0, x: x + 14, y: ty + 40, size: 26, bold: true, within: box)
        c.text(tile.1, x: x + 14, y: ty + 62, size: 12, fill: Ink.text2, within: box)
        c.text(tile.2, x: x + 14, y: ty + 78, size: 12, fill: Ink.text2, within: box)
    }
    y += Double((tiles.count + cols - 1) / cols) * (th + 12) + 8
    return c.finish(height: y, aria: title)
}

private func loadJSON(_ p: String) -> [String: Any]? {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: p)) else { return nil }
    return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
}

/// A record whose conditions carry `cpu_reference_contended` (the reason, a string) was taken while something else
/// held CPU cores, so its CPU timings (libjpeg-turbo, ImageIO, and the hybrid, which also runs on the CPU) are not
/// comparable. Charts and README tables then show only the Metal-only numbers for that machine and say why.
/// Any value except a missing key, null or false marks the run (fails closed); a non-empty string is the reason.
func cpuContended(_ c: [String: Any]) -> String? {
    guard let v = c["cpu_reference_contended"], !(v is NSNull) else { return nil }
    if let b = v as? Bool, b == false { return nil }
    if let r = v as? String, !r.trimmingCharacters(in: .whitespaces).isEmpty { return r }
    return "marked CPU-contended in its record"
}
/// implementations whose timings depend on the CPU
let cpuTimedImpls: Set<String> = ["libjpeg-turbo", "imageio", "hybrid"]
let notCompared = "not compared: CPU contended"

/// "M1 Max MacBook Pro" (large header) and the spec line below it
func machineHeader(_ c: [String: Any]) -> (name: String, spec: String) {
    let chip = (c["chip"] as? String ?? "?").replacingOccurrences(of: "Apple ", with: "")
    let model = c["model_name"] as? String ?? ""
    var spec = conditionLine(c) + ", \(c["reference"] ?? "?")"
    if let why = cpuContended(c) { spec += "\nCPU timings not shown: \(why)" }
    return ("\(chip) \(model)".trimmingCharacters(in: .whitespaces), spec)
}

private func conditionLine(_ c: [String: Any]) -> String {
    "\(c["chip"] ?? "?") (\(c["gpu_cores"] ?? "?")-core GPU, \(c["memory_gb"] ?? "?") GB), macOS \(c["macos"] ?? "?"), \(c["power"] ?? "?"), load \((c["load_average"] as? String)?.split(separator: " ").first ?? "?"), \(c["date"] ?? "?")"
}


private func fmtV(_ v: Double) -> String { v >= 100 ? String(format: "%.0f", v) : v >= 10 ? String(format: "%.1f", v) : String(format: "%.2f", v) }
private func rateText(_ v: Double) -> String { v >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v) }
/// "13.0x faster than libjpeg-turbo on 1 core" (or slower), comparing our time with libjpeg-turbo's on the same Mac
private func versusTurbo(_ ours: Double, _ cpu: Double?) -> String? {
    guard let cpu, cpu > 0, ours > 0 else { return nil }
    return cpu >= ours ? String(format: "%.1fx faster than libjpeg-turbo on 1 core", cpu / ours)
                       : String(format: "%.1fx slower than libjpeg-turbo on 1 core", ours / cpu)
}

func runCharts(results: String, out: String) -> Bool {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)
    let benchDir = results + "/bench"
    let files = ((try? fm.contentsOfDirectory(atPath: benchDir)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
    let runs = files.compactMap { f -> (String, [String: Any], [[String: Any]])? in
        guard let j = loadJSON(benchDir + "/" + f), let c = j["conditions"] as? [String: Any], let r = j["records"] as? [[String: Any]] else { return nil }
        return (f, c, r)
    }
    var written: [String] = [], refused: [String] = []
    func emit(_ name: String, _ svg: String?) {
        guard let svg else { refused.append(name); return }
        do { try svg.write(toFile: "\(out)/\(name).svg", atomically: true, encoding: .utf8); written.append(name) }
        catch { print("chart \(name): cannot write \(out)/\(name).svg: \(error)"); refused.append(name) }
    }
    // one run per chip: the latest (file names sort by date and time), so the charts reflect the current method;
    // older runs stay in results/bench as history, flawed ones move to results/bench/rejected with the reason.
    // The machine with the most GPU cores comes first.
    let latestPerChip = Dictionary(grouping: runs, by: { $0.1["chip"] as? String ?? "?" })
        .compactMap { $0.value.max { $0.0 < $1.0 } }
        .sorted { ($0.1["gpu_cores"] as? Int ?? 0) > ($1.1["gpu_cores"] as? Int ?? 0) }
    // A CPU-contended run keeps only its Metal-only records here, so its CPU bars and ratios are not drawn.
    let machines = latestPerChip.map { m -> (String, [String: Any], [[String: Any]]) in
        cpuContended(m.1) == nil ? m : (m.0, m.1, m.2.filter { !cpuTimedImpls.contains($0["impl"] as? String ?? "") })
    }
    let heads = machines.map { m -> ColumnHead in let h = machineHeader(m.1); return ColumnHead(name: h.name, spec: h.spec) }
    // per-call charts: exact-jpeg-metal (with how it compares with libjpeg-turbo on 1 core), libjpeg-turbo, ImageIO
    let perCallImpls: [(impl: String, name: String, fill: String)] = [
        ("metal", "exact-jpeg-metal", Fill.ours), ("libjpeg-turbo", "libjpeg-turbo, 1 CPU core", Fill.turbo1), ("imageio", "Apple ImageIO", Fill.imageio)]
    func caseKey(_ r: [String: Any]) -> String { "\(r["op"]!) \(r["width"]!)x\(r["height"]!) q\(r["quality"]!) \(r["subsampling"]!)" }
    func taskRows(_ op: String) -> [BarRow] {
        guard let ref = machines.first else { return [] }
        return ref.2.filter { $0["op"] as? String == op && $0["impl"] as? String == "metal" && $0["api"] == nil }.map { r in
            let key = caseKey(r)
            let mb = String(format: "%.1f MB", Double(r["bytes"] as? Int ?? 0) / 1e6)
            let title = (op == "decode" ? "Decode " : "Encode ") + key.dropFirst(7) + (op == "decode" ? " (\(mb) file)" : " (\(mb) output)")
            let cells = machines.map { m -> [Bar?] in
                let ms = perCallImpls.map { p in m.2.first { caseKey($0) == key && $0["impl"] as? String == p.impl && $0["api"] == nil }?["wall_ms"] as? Double }
                return perCallImpls.indices.map { k in
                    ms[k].map { Bar(name: perCallImpls[k].name, value: $0, valueText: fmtV($0) + " ms",
                                    comparison: k == 0 ? versusTurbo($0, ms[1]) : nil, fill: perCallImpls[k].fill) }
                }
            }
            return BarRow(title: String(title), cells: cells)
        }
    }
    let corpusLine = "Corpus: \(machines.first?.1["corpus"] ?? "?"); median of \(machines.first?.2.first?["iters"] ?? "?") runs; wall time of the whole call. Each column is one Mac against itself."
    let msAxis = "wall time per call (ms)"
    if !machines.isEmpty {
        emit("decode-times", gridChart("decode-times", title: "Decoding a 6720x4480 (30 MP) JPEG, one image at a time", higherIsBetter: false,
                                       subtitle: [corpusLine], columns: heads, rows: taskRows("decode"), axisLabel: msAxis,
                                       notes: ["exact-jpeg-metal's output is byte-identical to libjpeg-turbo's; Apple ImageIO's is not."]))
        emit("encode-times", gridChart("encode-times", title: "Encoding JPEGs, one image at a time", higherIsBetter: false,
                                       subtitle: [corpusLine], columns: heads, rows: taskRows("encode"), axisLabel: msAxis,
                                       notes: ["exact-jpeg-metal writes the same bytes as libjpeg-turbo; Apple ImageIO is shown at its closest file size."]))
        // small-image overhead: per variant (warm GPU, first call after idle), wall vs GPU busy vs libjpeg-turbo
        let variants = Array(Set(machines.flatMap { m in m.2.filter { $0["op"] as? String == "encode" && $0["width"] as? Int == 1200 && $0["impl"] as? String == "metal" }
            .map { ($0["api"] as? String) ?? "" } })).sorted()
        let ovRows = variants.map { v in
            BarRow(title: v.isEmpty ? "Warm GPU, one call per image" : v.prefix(1).uppercased() + v.dropFirst(), cells: machines.map { m -> [Bar?] in
                let recs = m.2.filter { $0["op"] as? String == "encode" && $0["width"] as? Int == 1200 }
                let r = recs.first { $0["impl"] as? String == "metal" && (($0["api"] as? String) ?? "") == v }
                let cpu = recs.first { $0["impl"] as? String == "libjpeg-turbo" && $0["api"] == nil }?["wall_ms"] as? Double
                let wall = r?["wall_ms"] as? Double, gpu = r?["gpu_ms"] as? Double
                return [wall.map { Bar(name: "exact-jpeg-metal, wall time", value: $0, valueText: fmtV($0) + " ms", comparison: versusTurbo($0, cpu), fill: Fill.ours) },
                        gpu.map { Bar(name: "exact-jpeg-metal, GPU busy time", value: $0, valueText: fmtV($0) + " ms", fill: Fill.oursGPU) },
                        cpu.map { Bar(name: "libjpeg-turbo, 1 CPU core", value: $0, valueText: fmtV($0) + " ms", fill: Fill.turbo1) }]
            })
        }
        emit("small-image-overhead", gridChart("small-image-overhead", title: "Encoding a 1200x800 JPEG (q87 4:2:0): per-call overhead",
                                               higherIsBetter: false,
                                               subtitle: ["Corpus: \(machines.first?.1["corpus"] ?? "?"); per image. Each column is one Mac against itself. Wall time is what the caller waits; GPU busy time is the part the GPU spends working."],
                                               columns: heads, rows: ovRows, axisLabel: msAxis,
                                               notes: ["The gap between wall and GPU busy time is submission and completion latency; after the GPU has idled, the first call also waits for it to clock up."]))
    }
    // batch throughput: images per second (higher is better); the fill follows the implementation, the variant is
    // in each bar's name
    let tpVariants: [(impl: String, threads: Int?, name: String, fill: String, gpuOnly: Bool)] = [
        ("metal", 1, "exact-jpeg-metal, 1 in flight", Fill.ours, true),
        ("metal", 2, "exact-jpeg-metal, 2 in flight", Fill.ours, true),
        ("metal-batch16", 1, "exact-jpeg-metal, batches of 16", Fill.ours, true),
        ("hybrid", nil, "exact-jpeg-metal + libjpeg-turbo on the other cores", Fill.ours, false),
        ("libjpeg-turbo", 1, "libjpeg-turbo, 1 CPU core", Fill.turbo1, false),
        ("libjpeg-turbo", nil, "libjpeg-turbo, all CPU cores", Fill.turboAll, false),
        ("imageio", 1, "Apple ImageIO, 1 thread", Fill.imageio, false),
        ("imageio", nil, "Apple ImageIO, all CPU cores", Fill.imageio, false),
    ]
    func tpName(_ k: Int, cores: Int) -> String {
        tpVariants[k].threads == nil ? tpVariants[k].name.replacingOccurrences(of: "all CPU cores", with: "all \(cores) CPU cores") : tpVariants[k].name
    }
    let tpMachines = machines.filter { $0.2.contains { ($0["op"] as? String ?? "").hasPrefix("throughput") } }
    if let tref = tpMachines.first {
        let tasks = tref.2.filter { ($0["op"] as? String ?? "").hasPrefix("throughput") && $0["impl"] as? String == "metal" && $0["threads"] as? Int == 1 }
        let rows = tasks.map { r -> BarRow in
            let cs = r["case"] as! String
            let rates = tpMachines.map { m -> [Double?] in
                let cores = m.1["cpu_cores"] as? Int ?? 0
                return tpVariants.map { v in
                    m.2.first { $0["case"] as? String == cs && $0["impl"] as? String == v.impl &&
                                ($0["threads"] as? Int) == (v.threads ?? cores) && ($0["op"] as? String ?? "").hasPrefix("throughput") }?["images_per_s"] as? Double
                }
            }
            // verdict per machine: our best GPU-only rate against the fastest alternative
            let notes = zip(tpMachines, rates).map { (m, cell) -> String in
                if cpuContended(m.1) != nil { return "exact-jpeg-metal only (\(notCompared))" }
                let cores = m.1["cpu_cores"] as? Int ?? 0
                let ours = tpVariants.indices.filter { tpVariants[$0].gpuOnly }.compactMap { cell[$0] }.max() ?? 0
                let alts = tpVariants.indices.filter { tpVariants[$0].impl != "metal" && tpVariants[$0].impl != "metal-batch16" && tpVariants[$0].impl != "hybrid" }
                guard let best = alts.max(by: { (cell[$0] ?? 0) < (cell[$1] ?? 0) }), let bv = cell[best], bv > 0, ours > 0 else { return "" }
                return ours >= bv ? String(format: "exact-jpeg-metal (GPU only) %.1fx faster than the fastest alternative (%@)", ours / bv, tpName(best, cores: cores))
                                  : String(format: "exact-jpeg-metal (GPU only) %.1fx slower than the fastest alternative (%@)", bv / ours, tpName(best, cores: cores))
            }
            let cells = zip(tpMachines, rates).map { (m, cell) -> [Bar?] in
                let cores = m.1["cpu_cores"] as? Int ?? 0
                return tpVariants.indices.map { k in cell[k].map { Bar(name: tpName(k, cores: cores), value: $0, valueText: rateText($0) + " images/s", fill: tpVariants[k].fill) } }
            }
            return BarRow(title: cs.prefix(1).uppercased() + cs.dropFirst(), notes: notes, cells: cells)
        }
        let theads = tpMachines.map { m -> ColumnHead in
            let h = machineHeader(m.1)
            return ColumnHead(name: h.name, spec: h.spec + "\nCPU: \(m.1["cpu_cores"] ?? "?") cores (\(m.1["cpu_performance_cores"] ?? "?") performance + \(m.1["cpu_efficiency_cores"] ?? "?") efficiency)")
        }
        emit("throughput", gridChart("throughput", title: "Batch throughput", higherIsBetter: true,
                                     subtitle: ["Corpus: \(tref.1["corpus"] ?? "?"); each variant runs for at least 1.5 s with its workers warmed, the GPU warmed first. Each column is one Mac against itself."],
                                     columns: theads, rows: rows, axisLabel: "throughput (images/s)",
                                     notes: ["libjpeg-turbo cannot split one image across cores, so its all-core rate runs one image per core at a time; the single-image charts show the time for one image.",
                                             "\"In flight\": decoders or encoders working at once. The hybrid runs exact-jpeg-metal batches and libjpeg-turbo on the remaining CPU cores; both outputs are exact."]))
    }
    // the PC library's public set: the headline (the machine with the most GPU cores) and the per-Mac medians
    let pcRuns = loadPCSetRuns(results)
    if let top = pcRuns.first { emit("headline", headlineChart(top)) } else { print("headline: no full pc-set record in \(results)/public") }
    if pcRuns.count > 1 { emit("public-set-devices", publicSetDevicesChart(pcRuns)) }
    // exactness and fuzzing summary
    if let e = loadJSON(results + "/exactness.json") {
        let d = e["decode"] as? [String: Any] ?? [:], en = e["encode"] as? [String: Any] ?? [:]
        let fz = e["fuzz"] as? [String: Any] ?? [:], sv = e["fuzz_shader_validation"] as? [String: Any] ?? [:]
        let fc = fz["counts"] as? [String: Any] ?? [:], ff = (fz["findings"] as? [String: Any] ?? [:]).count
        let svc = (sv["findings"] as? [String: Any] ?? [:]).count
        let nf = NumberFormatter(); nf.numberStyle = .decimal
        func f(_ x: Any?) -> String { nf.string(from: NSNumber(value: (x as? Int) ?? 0)) ?? "?" }
        let exactAll = (fc["decoded_exact"] as? Int ?? 0) + (fc["decoded_exact_with_benign_warning"] as? Int ?? 0)
        let tiles: [(String, String, String)] = [
            ("\(f(d["decodes_exact"])) / \(f((d["decodes_exact"] as? Int ?? 0) + (d["wrong"] as? Int ?? 0)))", "decodes byte-identical", "to libjpeg-turbo 3.2.0"),
            ("\(f(en["identical"])) / \(f(en["files"]))", "encoded files", "byte-identical"),
            ("\(f(d["declined_as_expected"])) / \(f(d["declined_as_expected"]))", "progressive decodes declined,", "as they must be"),
            ("\(f(fz["iterations"]))", "fuzzed files: \(ff) findings", "\(f(fc["declined"])) declined, \(f(exactAll)) exact"),
            ("\(f(sv["iterations"]))", "fuzzed under shader validation:", "\(f(e["shader_validation_reports"])) reports, \(svc) findings"),
            ("SHA-256", "manifest pins the target:", "libjpeg-turbo 3.2.0 outputs"),
        ]
        let c = e["conditions"] as? [String: Any] ?? [:]
        emit("exactness", tilesChart("exactness", title: "Exactness and robustness",
                                     subtitle: [conditionLine(c), "Synthetic corpus only (ejm synthetic v1); scripts/test.sh"], tiles: tiles))
    } else { print("exactness chart: results/exactness.json missing (run scripts/test.sh)") }
    print("charts written to \(out): \(written.map { $0 + ".svg" }.joined(separator: ", "))")
    if !refused.isEmpty { print("charts REFUSED (not written, see above): \(refused.joined(separator: ", "))") }
    if out == "docs/images" && FileManager.default.fileExists(atPath: "README.md") {
        replaceGenerated("README.md", readmeSections(runs: latestPerChip))
        print("README.md: generated sections updated from the same results")
    }
    return refused.isEmpty
}

// ---- the PC library's public set (`ejm pc-set` records: results/public/*-pc-set.json) ----

/// A full (not --quick) `ejm pc-set` record: its file name, chip ("M1 Max"), GPU cores and the JSON.
struct PCSetRun { let file: String; let chip: String; let gpuCores: Int; let json: [String: Any] }

/// the latest full pc-set record per chip, the chip with the most GPU cores first
func loadPCSetRuns(_ results: String) -> [PCSetRun] {
    let dir = results + "/public"
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix("-pc-set.json") }.sorted()
    let runs = files.compactMap { f -> PCSetRun? in
        guard let j = loadJSON(dir + "/" + f), j["quick"] as? Bool == false, let g = j["gpu"] as? [String: Any],
              let chip = g["chip"] as? String, let cores = g["cores"] as? Int, j["files"] is [[String: Any]], j["summary"] is [String: Any] else { return nil }
        return PCSetRun(file: f, chip: chip.replacingOccurrences(of: "Apple ", with: ""), gpuCores: cores, json: j)
    }
    return Dictionary(grouping: runs, by: \.chip).compactMap { $0.value.last }.sorted { $0.gpuCores > $1.gpuCores }
}

/// the four decoders of a pc-set record: its key, the name on the bar, the fill
private let pcDecoders: [(key: String, name: String, fill: String)] = [
    ("this library", "exact-jpeg-metal", Fill.ours), ("libjpeg-turbo, one thread", "libjpeg-turbo, 1 CPU core", Fill.turbo1),
    ("Apple ImageIO", "Apple ImageIO", Fill.imageio), ("VideoToolbox (Apple hardware JPEG)", "VideoToolbox (Apple hardware decoder)", Fill.videotoolbox)]
/// display names of the set's source folders
private func pcSourceName(_ folder: String) -> String {
    switch folder {
    case "imagecompression_info": return "imagecompression.info"
    case "libjpeg_turbo_3dtest": return "libjpeg-turbo's test frames"
    default: return folder
    }
}

/// images, settings, megapixel range and calls per median of a pc-set record
private func pcSetShape(_ j: [String: Any]) -> (images: Int, settings: Int, minMP: Double, maxMP: Double, iters: String) {
    let files = j["files"] as? [[String: Any]] ?? [], mp = files.compactMap { $0["megapixels"] as? Double }
    let iters = (j["timing"] as? String).flatMap { s -> String? in
        guard let r = s.range(of: "median of ") else { return nil }
        return s[r.upperBound...].split(separator: " ").first.map(String.init)
    } ?? "?"
    return (Set(files.compactMap { $0["image"] as? String }).count, Set(files.compactMap { $0["setting"] as? String }).count, mp.min() ?? 0, mp.max() ?? 0, iters)
}

/// Two panels, from one pc-set record (the machine with the most GPU cores). Left: the big_building q95_420 decode
/// (found by image and setting name) by each decoder. Right: pixel identity against libjpeg-turbo over every JPEG of
/// the set, read from the record's summary. nil (and the reason printed) when something is missing.
func headlineChart(_ run: PCSetRun) -> String? {
    func fail(_ why: String) -> String? { print("chart headline: \(run.file): \(why)"); return nil }
    let j = run.json, files = j["files"] as! [[String: Any]], summary = j["summary"] as! [String: Any]
    let image = "big_building", setting = "q95_420"
    guard let row = files.first(where: { $0["image"] as? String == image && $0["setting"] as? String == setting }) else {
        return fail("no \(image) \(setting) row")
    }
    let ms = row["ms"] as? [String: Any] ?? [:]
    let times = pcDecoders.map { ms[$0.key] as? Double }
    guard times.allSatisfy({ $0 != nil }), let mp = row["megapixels"] as? Double else { return fail("\(image) \(setting) lacks a time or its megapixels") }
    let t = times.map { $0! }
    guard let st = (j["settings"] as? [[String: Any]])?.first(where: { $0["name"] as? String == setting }), let q = st["quality"] as? Int else {
        return fail("setting \(setting) is not described in \"settings\"")
    }
    let sampling = (st["pillow"] as? String).flatMap { p in ["4:2:0", "4:2:2", "4:4:4"].first { p.contains($0) } } ?? "?"
    let inputs = j["inputs"] as? [[String: Any]] ?? []
    let source = inputs.first { ($0["file"] as? String ?? "").hasPrefix("\(image)__") }.flatMap { ($0["source"] as? String)?.split(separator: "/").first }.map { pcSourceName(String($0)) } ?? "?"
    let shape = pcSetShape(j), iters = shape.iters
    // identity: exact-jpeg-metal from pixels_identical of jpegs; the others from identical of identical + differ
    guard let total = summary["jpegs"] as? Int, let ours = summary["pixels_identical"] as? Int, total > 0 else { return fail("summary lacks jpegs / pixels_identical") }
    let others = summary["others"] as? [String: Any] ?? [:]
    func other(_ k: String) -> (identical: Int, compared: Int, failed: Int, maxDiff: Int)? {
        guard let o = others[k] as? [String: Any], let i = o["identical"] as? Int, let d = o["differ"] as? Int else { return nil }
        return (i, i + d, o["failed"] as? Int ?? 0, o["max_diff"] as? Int ?? 0)
    }
    guard let iio = other(pcDecoders[2].key), let vt = other(pcDecoders[3].key) else { return fail("summary lacks the ImageIO or VideoToolbox identity") }
    if iio.failed + vt.failed > 0 { return fail("ImageIO or VideoToolbox failed on some files; the headline would hide them") }
    let images = shape.images, settings = shape.settings
    let folders = Set(inputs.compactMap { ($0["source"] as? String)?.split(separator: "/").first.map(String.init) }).sorted().map(pcSourceName)

    let W = 1280.0, gap = 40.0, pw = (W - 40 - gap) / 2, px = [20.0, 20 + pw + gap]
    let c = SVGCanvas("headline", width: W)
    let h1 = header(c, x: px[0], y: 34, width: pw, title: "Decode one \(Int(mp.rounded())) MP camera photo, one at a time", size: 19, higherIsBetter: false,
                    subtitle: [String(format: "%@ from %@, quality %d %@, %.0f MP, median of %@ calls; %@, %d-core GPU.", image, source, q, sampling, mp, iters, run.chip, run.gpuCores)])
    let h2 = header(c, x: px[1], y: 34, width: pw, title: "Pixels identical to libjpeg-turbo, on \(total) public test JPEGs", size: 19, higherIsBetter: true,
                    subtitle: ["Each decoder's RGB output compared byte for byte with libjpeg-turbo's."])
    let barsY = max(h1, h2) + 24
    let left = pcDecoders.indices.map { k in
        Bar(name: pcDecoders[k].name, value: t[k], valueText: fmtV(t[k]) + " ms", comparison: k == 0 ? versusTurbo(t[0], t[1]) : nil, fill: pcDecoders[k].fill)
    }
    let (top, step) = fitScale(left, plotW: pw)
    var y1 = drawBars(c, left, left: px[0], plotW: pw, y0: barsY, top: top, step: step, axisLabel: "wall time to decode the image (ms)", tick: { tickText($0, step) })
    for l in wrapWidth("exact-jpeg-metal's pixels are byte-identical to libjpeg-turbo's; Apple ImageIO's and VideoToolbox's are not (right panel).", pw, size: 11.5) {
        y1 += 16; c.text(l, x: px[0], y: y1, size: 11.5, fill: Ink.text2)
    }
    func idText(_ i: Int, _ n: Int, _ md: Int?) -> String { "\(i) of \(n) files identical" + (i < n ? " (max diff \(md ?? 0))" : "") }
    let right = [Bar(name: "exact-jpeg-metal", value: Double(ours) / Double(total) * 100, valueText: idText(ours, total, nil), fill: Fill.ours),
                 Bar(name: "Apple ImageIO", value: Double(iio.identical) / Double(iio.compared) * 100, valueText: idText(iio.identical, iio.compared, iio.maxDiff), fill: Fill.imageio),
                 Bar(name: pcDecoders[3].name, value: Double(vt.identical) / Double(vt.compared) * 100, valueText: idText(vt.identical, vt.compared, vt.maxDiff), fill: Fill.videotoolbox)]
    var y2 = drawBars(c, right, left: px[1], plotW: pw, y0: barsY, top: 100, step: 25, axisLabel: "files with pixels identical to libjpeg-turbo (% of the files)",
                      tick: { String(format: "%.0f%%", $0) })
    let small = [
        "\(images) images from \(folders.joined(separator: " and ")), \(settings) settings each: the same set as exact-gpu-jpeg (https://github.com/mrluker/exact-gpu-jpeg).",
        "max diff: the largest difference in one 8-bit channel value (0 to 255). VideoToolbox outputs BGRA, so its comparison includes its own YCbCr to RGB conversion.",
    ]
    for (i, s) in small.enumerated() {
        if i > 0 { y2 += 5 }
        for l in wrapWidth(s, pw, size: 11.5) { y2 += 16; c.text(l, x: px[1], y: y2, size: 11.5, fill: Ink.text2) }
    }
    var y = max(y1, y2) + 14
    c.line(20, y, W - 20, y, stroke: Ink.grid)
    for l in wrapWidth("Data: results/public/\(run.file). Measured on one Mac: \(run.chip), \(run.gpuCores)-core GPU.", W - 40, size: 12) {
        y += 20; c.text(l, x: 20, y: y, size: 12, fill: Ink.text2)
    }
    return c.finish(height: y + 16, aria: "Left: decoding \(image) (\(Int(mp.rounded())) MP), " +
                    pcDecoders.indices.map { "\(pcDecoders[$0].name) \(fmtV(t[$0])) ms" }.joined(separator: ", ") +
                    ". Right: pixels identical to libjpeg-turbo, exact-jpeg-metal \(ours) of \(total), Apple ImageIO \(iio.identical) of \(iio.compared), VideoToolbox \(vt.identical) of \(vt.compared).")
}

/// One column per chip: the median decode time over every JPEG of the set, per decoder.
func publicSetDevicesChart(_ runs: [PCSetRun]) -> String? {
    var cols: [ColumnHead] = [], cells: [[Bar?]] = [], counts: [Int] = []
    for r in runs {
        let files = r.json["files"] as! [[String: Any]]
        var meds: [Double] = []
        for d in pcDecoders {
            let v = files.compactMap { ($0["ms"] as? [String: Any])?[d.key] as? Double }.sorted()
            if v.count != files.count || v.isEmpty { print("chart public-set-devices: \(r.file): \(d.key) has no time for \(files.count - v.count) files"); return nil }
            meds.append(v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2)
        }
        let ver = r.json["versions"] as? [String: Any] ?? [:], cond = r.json["conditions"] as? [String: Any] ?? [:]
        cols.append(ColumnHead(name: r.chip, spec: "\(r.gpuCores)-core GPU, macOS \(ver["macOS"] ?? "?"), libjpeg-turbo \(ver["libjpeg-turbo runtime"] ?? "?"), load \((cond["load_average_before"] as? String)?.split(separator: " ").first ?? "?") at start; \(r.file)"))
        cells.append(pcDecoders.indices.map { k in
            Bar(name: pcDecoders[k].name, value: meds[k], valueText: fmtV(meds[k]) + " ms", comparison: k == 0 ? versusTurbo(meds[0], meds[1]) : nil, fill: pcDecoders[k].fill)
        })
        counts.append(files.count)
    }
    guard let n = counts.first, counts.allSatisfy({ $0 == n }), let first = runs.first else { print("chart public-set-devices: the records hold different numbers of JPEGs"); return nil }
    let shape = pcSetShape(first.json)
    return gridChart("public-set-devices", title: "Median decode time over the \(n) public test JPEGs, per Mac", higherIsBetter: false,
                     subtitle: [String(format: "The set of exact-gpu-jpeg: %d images, %d settings each, %.1f to %.0f MP. Per JPEG the median of %@ calls; the bar is the median over the %d JPEGs. Each column is one Mac against itself.",
                                       shape.images, shape.settings, shape.minMP, shape.maxMP, shape.iters, n)],
                     columns: cols, rows: [BarRow(title: "Median over \(n) JPEGs", cells: cells)], axisLabel: "median wall time per JPEG (ms)",
                     notes: ["Only exact-jpeg-metal's pixels are identical to libjpeg-turbo's on every file."])
}


// ---- README text generated from the same results as the charts, so the numbers always match ----

/// Replaces the text between `<!-- generated:NAME -->` and `<!-- /generated:NAME -->` in the file.
func replaceGenerated(_ path: String, _ sections: [String: String]) {
    guard var s = try? String(contentsOfFile: path, encoding: .utf8) else { return }
    for (name, text) in sections {
        let open = "<!-- generated:\(name) -->", close = "<!-- /generated:\(name) -->"
        guard let a = s.range(of: open), let b = s.range(of: close, range: a.upperBound..<s.endIndex) else {
            print("README: no markers for \(name)"); continue
        }
        s.replaceSubrange(a.upperBound..<b.lowerBound, with: "\n" + text + "\n")
    }
    try? s.write(toFile: path, atomically: true, encoding: .utf8)
}

// The exactness numbers are not in the headline: the README states them in its own table, from several machines.
func readmeSections(runs: [(String, [String: Any], [[String: Any]])]) -> [String: String] {
    // width and height both: 3840x2560 and 3840x2880 share width, quality and subsampling
    func rec(_ recs: [[String: Any]], _ op: String, _ w: Int, _ h: Int, _ q: Int, _ ss: String, _ impl: String) -> [String: Any]? {
        recs.first { $0["op"] as? String == op && $0["width"] as? Int == w && $0["height"] as? Int == h && $0["quality"] as? Int == q &&
                     $0["subsampling"] as? String == ss && $0["impl"] as? String == impl && $0["api"] == nil }
    }
    func ms(_ r: [String: Any]?, _ k: String = "wall_ms") -> Double? { r?[k] as? Double }
    // the per-call rows: one Metal record per task. Throughput records also have impl "metal" (1 and 2 concurrent)
    // but no wall time, so they belong only in the throughput table.
    func perCall(_ r: [String: Any]) -> Bool {
        r["impl"] as? String == "metal" && r["api"] == nil && !(r["op"] as? String ?? "").hasPrefix("throughput")
    }
    func f(_ v: Double?) -> String { v.map { $0 >= 100 ? String(format: "%.0f", $0) : $0 >= 10 ? String(format: "%.1f", $0) : String(format: "%.2f", $0) } ?? "n/a" }
    func ratio(_ gpu: Double?, _ cpu: Double?) -> String {
        guard let g = gpu, let c = cpu, g > 0 else { return "" }
        return c >= g ? String(format: "%.1fx faster than libjpeg-turbo on 1 CPU core", c / g) : String(format: "%.1fx slower than libjpeg-turbo on 1 CPU core (per-call overhead)", g / c)
    }
    // headline, in the same machine order as the tables; a CPU-contended run gives only its Metal times, with the reason
    var headline: [String] = [], tables: [String] = []
    for (_, c, recs) in runs {
        let m = machineHeader(c)
        let dec = rec(recs, "decode", 6720, 4480, 95, "4:2:2", "metal"), decCPU = rec(recs, "decode", 6720, 4480, 95, "4:2:2", "libjpeg-turbo")
        let ban = rec(recs, "encode", 3840, 2560, 95, "4:4:4", "metal"), banCPU = rec(recs, "encode", 3840, 2560, 95, "4:4:4", "libjpeg-turbo")
        let gpu = "on an \(m.name) (\(c["gpu_cores"] ?? "?")-core GPU) it decodes a 6720x4480 camera-size JPEG in \(f(ms(dec))) ms"
        if let why = cpuContended(c) {
            headline.append(gpu + " and encodes a 3840x2560 q95 web banner in \(f(ms(ban))) ms (CPU timings of that run not compared: \(why))")
            continue
        }
        let cpuDec = ms(decCPU) ?? 0, gpuDec = ms(dec) ?? 1
        var line = gpu + ", " + String(format: "%.1fx", cpuDec / gpuDec) + " faster than libjpeg-turbo on 1 CPU core, and encodes a " +
                   "3840x2560 q95 web banner in \(f(ms(ban))) ms (" + String(format: "%.1fx", (ms(banCPU) ?? 0) / (ms(ban) ?? 1)) + ")"
        // the same machine with every CPU core running libjpeg-turbo, one image per core
        let n = c["cpu_cores"] as? Int ?? 0
        func tput(_ cs: String, _ impl: String, _ th: Int) -> Double? {
            recs.first { $0["case"] as? String == cs && $0["impl"] as? String == impl && $0["threads"] as? Int == th &&
                         ($0["op"] as? String ?? "").hasPrefix("throughput") }?["images_per_s"] as? Double
        }
        func rate(_ v: Double) -> String { v >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v) }
        let dc = "decode 6720x4480 q95 4:2:2", ec = "encode 3840x2560 q95 4:4:4"
        if let dm = tput(dc, "metal", 2), let dt = tput(dc, "libjpeg-turbo", n), let em = tput(ec, "metal", 2), let et = tput(ec, "libjpeg-turbo", n) {
            line += "; against libjpeg-turbo on all \(n) CPU cores, 2 concurrent Metal decoders reach \(rate(dm)) images/s against \(rate(dt)), " +
                    "and 2 concurrent encoders \(rate(em)) against \(rate(et))"
        }
        headline.append(line)
    }
    for (_, c, recs) in runs {
        let m = machineHeader(c), contended = cpuContended(c) != nil
        var t = "**\(m.name)** (\(m.spec.replacingOccurrences(of: "\n", with: "; ")); corpus: \(c["corpus"] ?? "?"); median of \(recs.first?["iters"] ?? "?") runs)\n\n"
        t += "| task | Metal exact wall (GPU) | vs libjpeg-turbo on 1 CPU core | libjpeg-turbo, 1 CPU core | Apple ImageIO (not byte-identical) |\n|---|---|---|---|---|\n"
        for r in recs where perCall(r) {
            let op = r["op"] as! String, w = r["width"] as! Int, h = r["height"] as! Int, q = r["quality"] as! Int, ss = r["subsampling"] as! String
            let cpu = ms(rec(recs, op, w, h, q, ss, "libjpeg-turbo")), iio = rec(recs, op, w, h, q, ss, "imageio")
            var iioText = contended ? notCompared : "\(f(ms(iio))) ms"
            // ImageIO's difference from libjpeg-turbo is a property of its output, not of the timing
            if op == "decode", let md = iio?["max_diff"] as? Int, let p = iio?["psnr_db"] as? Double { iioText += String(format: "; max diff %d, PSNR %.1f dB", md, p) }
            let size = String(format: "%.1f MB", Double(r["bytes"] as? Int ?? 0) / 1e6)
            t += "| \(op) \(w)x\(h) q\(q) \(ss) (\(size)) | \(f(ms(r))) ms (\(f(ms(r, "gpu_ms")))) | \(contended ? notCompared : ratio(ms(r), cpu)) | \(contended ? notCompared : f(cpu) + " ms") | \(iioText) |\n"
        }
        tables.append(t)
    }
    // speed-up table: tasks x machines, GPU wall time vs libjpeg-turbo on 1 CPU core of the same machine
    var sp = "| task | " + runs.map { machineHeader($0.1).name }.joined(separator: " | ") + " |\n|---|" + runs.map { _ in "---|" }.joined() + "\n"
    if let ref = runs.first {
        for r in ref.2 where perCall(r) {
            let op = r["op"] as! String, w = r["width"] as! Int, h = r["height"] as! Int, q = r["quality"] as! Int, ss = r["subsampling"] as! String
            sp += "| \(op) \(w)x\(h) q\(q) \(ss) |"
            for (_, cond, recs) in runs {
                if cpuContended(cond) != nil { sp += " \(notCompared) |"; continue }
                if let g = ms(rec(recs, op, w, h, q, ss, "metal")), let c = ms(rec(recs, op, w, h, q, ss, "libjpeg-turbo")) {
                    sp += c >= g ? String(format: " %.1fx faster |", c / g) : String(format: " %.1fx slower |", g / c)
                } else { sp += " n/a |" }
            }
            sp += "\n"
        }
    }
    // batch throughput tables: per machine, tasks x variants, images per second
    var tp = ""
    for (_, c, recs) in runs where recs.contains(where: { ($0["op"] as? String ?? "").hasPrefix("throughput") }) {
        let n = c["cpu_cores"] as? Int ?? 0
        let cols: [(String, String, Int)] = [("Metal exact, 1", "metal", 1), ("Metal exact, 2 concurrent", "metal", 2),
            ("Metal exact, batches of 16", "metal-batch16", 1), ("hybrid: GPU batches + other CPU cores", "hybrid", n),
            ("libjpeg-turbo, 1 CPU core", "libjpeg-turbo", 1), ("libjpeg-turbo, all \(n) CPU cores (one image per core)", "libjpeg-turbo", n),
            ("ImageIO, 1 thread", "imageio", 1), ("ImageIO, all \(n) CPU cores", "imageio", n)]
        let contended = cpuContended(c)
        tp += "**\(machineHeader(c).name)** (\(c["cpu_cores"] ?? "?") CPU cores: \(c["cpu_performance_cores"] ?? "?") performance + \(c["cpu_efficiency_cores"] ?? "?") efficiency; images per second, higher is better" +
              (contended.map { "; CPU and hybrid rates not compared: \($0)" } ?? "") + ")\n\n"
        tp += "| task | " + cols.map(\.0).joined(separator: " | ") + " |\n|---|" + cols.map { _ in "---|" }.joined() + "\n"
        var seen = Set<String>()
        for r in recs where (r["op"] as? String ?? "").hasPrefix("throughput") {
            let cs = r["case"] as! String
            if !seen.insert(cs).inserted { continue }
            tp += "| \(cs) |" + cols.map { col in
                let v = recs.first { $0["case"] as? String == cs && $0["impl"] as? String == col.1 && $0["threads"] as? Int == col.2 &&
                                     ($0["op"] as? String ?? "").hasPrefix("throughput") }?["images_per_s"] as? Double
                if v != nil && contended != nil && cpuTimedImpls.contains(col.1) { return " \(notCompared) |" }
                return v.map { $0 >= 100 ? String(format: " %.0f |", $0) : String(format: " %.1f |", $0) } ?? " n/a |"
            }.joined() + "\n"
        }
        tp += "\n"
    }
    let first = headline.first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? ""
    let rest = headline.dropFirst().map { "; " + $0 }.joined()
    return ["headline": first + rest + ".", "tables": tables.joined(separator: "\n"), "speedups": sp, "throughput": tp.isEmpty ? "(no throughput results yet: run ./scripts/bench.sh)" : tp]
}

