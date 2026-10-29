// Renders Rustle's app icon: one sugar-maple leaf drifting over a warm dusk squircle.
//
//   swift scripts/make-icon.swift [optional/path/to/preview-1024.png]
//
// Writes Resources/AppIcon.icns (via an .iconset in a temporary directory and `iconutil`).
// The leaf drawing mirrors Sources/Rustle/LeafArt.swift (scripts can't import the app module).

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Small helpers (same as LeafArt)

struct Vec {
    var x: CGFloat
    var y: CGFloat
    init(_ x: CGFloat, _ y: CGFloat) { self.x = x; self.y = y }
    static func + (a: Vec, b: Vec) -> Vec { Vec(a.x + b.x, a.y + b.y) }
    static func - (a: Vec, b: Vec) -> Vec { Vec(a.x - b.x, a.y - b.y) }
    static func * (a: Vec, k: CGFloat) -> Vec { Vec(a.x * k, a.y * k) }
    var length: CGFloat { (x * x + y * y).squareRoot() }
    var normalized: Vec { let l = max(length, 1e-9); return Vec(x / l, y / l) }
    func rotated(_ rad: CGFloat) -> Vec { Vec(x * cos(rad) - y * sin(rad), x * sin(rad) + y * cos(rad)) }
    func dot(_ o: Vec) -> CGFloat { x * o.x + y * o.y }
}

struct Rand {
    private var state: UInt64
    init(seed: UInt64) { state = seed ^ 0x2545_F491_4F6C_DD1D }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> CGFloat { CGFloat(Double(next() >> 11) / 9_007_199_254_740_992.0) }
    mutating func range(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * unit() }
    mutating func jitter(_ v: CGFloat, _ f: CGFloat) -> CGFloat { v * (1 + range(-f, f)) }
}

struct RGB {
    var r: CGFloat, g: CGFloat, b: CGFloat
    init(_ hex: UInt32) {
        r = CGFloat((hex >> 16) & 0xFF) / 255
        g = CGFloat((hex >> 8) & 0xFF) / 255
        b = CGFloat(hex & 0xFF) / 255
    }
    init(r: CGFloat, g: CGFloat, b: CGFloat) { self.r = r; self.g = g; self.b = b }
    func mix(_ o: RGB, _ t: CGFloat) -> RGB { RGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t) }
    func lighter(_ t: CGFloat) -> RGB { mix(RGB(r: 1, g: 0.97, b: 0.86), t) }
    func darker(_ t: CGFloat) -> RGB { mix(RGB(r: 0.10, g: 0.04, b: 0.02), t) }
    func cg(_ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func makeContext(_ w: Int, _ h: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    return ctx
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: srgb, colors: colors as CFArray, locations: locations)!
}

// MARK: - Leaf geometry (sugar maple, as in LeafArt)

enum KeyKind { case smooth, tip, corner }

struct Key {
    var p: Vec
    var kind: KeyKind
    init(_ x: CGFloat, _ y: CGFloat, _ kind: KeyKind = .smooth) { p = Vec(x, y); self.kind = kind }
    init(_ p: Vec, _ kind: KeyKind) { self.p = p; self.kind = kind }
}

struct Vein {
    var pts: [Vec]
    var w0: CGFloat
    var w1: CGFloat
    var major: Bool
}

func catmullRom(_ p0: Vec, _ p1: Vec, _ p2: Vec, _ p3: Vec, _ t: CGFloat) -> Vec {
    let t1 = max((p1 - p0).length.squareRoot(), 1e-4)
    let t2 = t1 + max((p2 - p1).length.squareRoot(), 1e-4)
    let t3 = t2 + max((p3 - p2).length.squareRoot(), 1e-4)
    let tt = t1 + (t2 - t1) * t
    let a1 = p0 * ((t1 - tt) / t1) + p1 * (tt / t1)
    let a2 = p1 * ((t2 - tt) / (t2 - t1)) + p2 * ((tt - t1) / (t2 - t1))
    let a3 = p2 * ((t3 - tt) / (t3 - t2)) + p3 * ((tt - t2) / (t3 - t2))
    let b1 = a1 * ((t2 - tt) / t2) + a2 * (tt / t2)
    let b2 = a2 * ((t3 - tt) / (t3 - t1)) + a3 * ((tt - t1) / (t3 - t1))
    return b1 * ((t2 - tt) / (t2 - t1)) + b2 * ((tt - t1) / (t2 - t1))
}

func outline(_ keys: [Key], wobble: CGFloat, _ rng: inout Rand) -> [Vec] {
    let n = keys.count
    var pts: [Vec] = []
    let step: CGFloat = 0.0015
    for i in 0..<n {
        let k1 = keys[i], k2 = keys[(i + 1) % n]
        let p1 = k1.p, p2 = k2.p
        let p0 = k1.kind == .smooth ? keys[(i + n - 1) % n].p : p1 * 2 - p2
        let p3 = k2.kind == .smooth ? keys[(i + 2) % n].p : p2 * 2 - p1
        let m = max(2, Int(((p2 - p1).length / step).rounded(.up)))
        for j in 0..<m { pts.append(catmullRom(p0, p1, p2, p3, CGFloat(j) / CGFloat(m))) }
    }
    let count = pts.count
    var s = [CGFloat](repeating: 0, count: count)
    for i in 1..<count { s[i] = s[i - 1] + (pts[i] - pts[i - 1]).length }
    let total = s[count - 1] + (pts[0] - pts[count - 1]).length
    let c1 = max(1, (total / 0.45).rounded()), c2 = max(2, (total / 0.16).rounded())
    let ph1 = rng.range(0, 2 * .pi), ph2 = rng.range(0, 2 * .pi)
    var out: [Vec] = []
    for i in 0..<count {
        let tan = (pts[(i + 1) % count] - pts[(i + count - 1) % count]).normalized
        let nrm = Vec(tan.y, -tan.x)
        let w = wobble * (0.6 * sin(2 * .pi * c1 * s[i] / total + ph1) + 0.4 * sin(2 * .pi * c2 * s[i] / total + ph2))
        out.append(pts[i] + nrm * w)
    }
    return out
}

func curve(_ a: Vec, _ b: Vec, bend: CGFloat, segments: Int = 16) -> [Vec] {
    let d = b - a
    let c = (a + b) * 0.5 + Vec(-d.y, d.x) * bend
    return (0...segments).map { i in
        let t = CGFloat(i) / CGFloat(segments), u = 1 - t
        return a * (u * u) + c * (2 * u * t) + b * (t * t)
    }
}

func hit(_ o: Vec, _ d: Vec, _ poly: [Vec]) -> CGFloat? {
    var best = CGFloat.greatestFiniteMagnitude
    for i in 0..<poly.count {
        let a = poly[i], e = poly[(i + 1) % poly.count] - a
        let den = d.x * e.y - d.y * e.x
        if abs(den) < 1e-12 { continue }
        let w = a - o
        let t = (w.x * e.y - w.y * e.x) / den, s = (w.x * d.y - w.y * d.x) / den
        if t > 1e-5 && s >= 0 && s <= 1 && t < best { best = t }
    }
    return best < .greatestFiniteMagnitude ? best : nil
}

struct Leaf {
    var outline: [Vec] = []
    var veins: [Vein] = []
    var petiole: [Vec] = []
}

/// Same construction as LeafArt.sugarMaple: five lobes radiating from the petiole junction.
func sugarMaple(seed: UInt64) -> Leaf {
    var r = Rand(seed: seed)
    let mainTeeth: [Key] = [Key(0.072, 0.845), Key(0.084, 0.772), Key(0.19, 0.80, .tip), Key(0.152, 0.70),
                            Key(0.29, 0.665, .tip), Key(0.19, 0.565), Key(0.168, 0.50)]
    let basalTeeth: [Key] = [Key(0.08, 0.80), Key(0.10, 0.70), Key(0.24, 0.68, .tip), Key(0.17, 0.56), Key(0.15, 0.48)]
    let basalPlain: [Key] = [Key(0.09, 0.80), Key(0.16, 0.64), Key(0.15, 0.48)]
    let side = r.range(46, 54), low = r.range(106, 118)
    struct Lobe { var angle: CGFloat; var length: CGFloat; var plus: [Key]; var minus: [Key] }
    let lobes = [
        Lobe(angle: low + r.range(-4, 4), length: r.jitter(0.44, 0.08), plus: basalPlain, minus: basalTeeth),
        Lobe(angle: side + r.range(-3, 3), length: r.jitter(0.86, 0.05), plus: mainTeeth, minus: mainTeeth),
        Lobe(angle: r.range(-3, 3), length: 1, plus: mainTeeth, minus: mainTeeth),
        Lobe(angle: -side + r.range(-3, 3), length: r.jitter(0.86, 0.05), plus: mainTeeth, minus: mainTeeth),
        Lobe(angle: -low + r.range(-4, 4), length: r.jitter(0.44, 0.08), plus: basalTeeth, minus: basalPlain),
    ]
    let sinus = [r.jitter(0.80, 0.05), r.jitter(0.74, 0.05), r.jitter(0.74, 0.05), r.jitter(0.80, 0.05)]
    var leaf = Leaf()
    var lists: [[Key]] = []
    var rays: [(Vec, Vec)] = []
    for lobe in lobes {
        let th = lobe.angle * .pi / 180, c = cos(th), s = sin(th), len = lobe.length
        let axis = Vec(s, c)
        func place(_ q: Vec) -> Vec { Vec((q.x * c + q.y * s) * len, (-q.x * s + q.y * c) * len) }
        var keys: [Key] = []
        var teeth: [Vec] = []
        for k in lobe.plus.reversed() {
            let j: CGFloat = k.kind == .tip ? 0.22 : 0.05
            let p = place(Vec(k.p.x * (1 + r.range(-j, j)), k.p.y + r.range(-j, j) * 0.05))
            if k.kind == .tip { teeth.append(p) }
            keys.append(Key(p, k.kind))
        }
        let tip = place(Vec(0, 1))
        keys.append(Key(tip, .tip))
        for k in lobe.minus {
            let j: CGFloat = k.kind == .tip ? 0.22 : 0.05
            let p = place(Vec(-k.p.x * (1 + r.range(-j, j)), k.p.y + r.range(-j, j) * 0.05))
            if k.kind == .tip { teeth.append(p) }
            keys.append(Key(p, k.kind))
        }
        lists.append(keys)
        leaf.veins.append(Vein(pts: curve(Vec(0, 0), tip * 0.95, bend: r.range(-0.035, 0.035)),
                               w0: 0.027 * len.squareRoot(), w1: 0.005, major: true))
        for t in teeth {
            let a = axis * max(0.2 * len, t.dot(axis) * 0.6)
            let b = a + (t - a) * 0.88
            let bend: CGFloat = (t - a).x * axis.y - (t - a).y * axis.x > 0 ? 0.08 : -0.08
            leaf.veins.append(Vein(pts: curve(a, b, bend: bend), w0: 0.013, w1: 0.003, major: false))
        }
        for sgn in [CGFloat(1), CGFloat(-1)] {
            rays.append((axis * (0.36 * len), axis.rotated(sgn * 55 * .pi / 180)))
        }
    }
    var keys: [Key] = []
    let first = lists[0][0].p, last = lists[lists.count - 1][lists[lists.count - 1].count - 1].p
    keys.append(Key((first + last) * 0.15, .corner))
    for (i, list) in lists.enumerated() {
        if i > 0 {
            let a = lists[i - 1][lists[i - 1].count - 1].p, b = list[0].p
            keys.append(Key((a + b) * (0.5 * sinus[i - 1]), .smooth))
        }
        keys += list
    }
    leaf.outline = outline(keys, wobble: 0.0045, &r)
    for (o, d) in rays {
        if let h = hit(o, d, leaf.outline) {
            let end = o + d * (h * 0.82)
            leaf.veins.append(Vein(pts: curve(o, end, bend: d.x >= 0 ? -0.06 : 0.06), w0: 0.01, w1: 0.0025, major: false))
        }
    }
    let pth = r.range(-14, 14) * .pi / 180, plen = r.range(0.15, 0.2) + 0.035
    let start = Vec(0, 0.035)
    leaf.petiole = curve(start, start + Vec(sin(pth) * plen, -cos(pth) * plen), bend: r.range(-0.22, 0.22))
    // Gentle bend and asymmetry, as in the sprite sheet.
    let bend = r.range(-0.06, 0.06), asym = r.range(-0.05, 0.05)
    func warp(_ p: Vec) -> Vec {
        let yy = max(p.y, 0)
        return Vec(p.x * (p.x > 0 ? 1 + asym : 1 - asym) + bend * yy * yy, p.y)
    }
    leaf.outline = leaf.outline.map(warp)
    leaf.petiole = leaf.petiole.map(warp)
    for i in leaf.veins.indices { leaf.veins[i].pts = leaf.veins[i].pts.map(warp) }
    return leaf
}

// MARK: - Leaf painting (same layers as LeafArt, tuned for a large single leaf)

func tapered(_ p: [CGPoint], w0: CGFloat, w1: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let n = p.count
    guard n >= 2 else { return path }
    var lens = [CGFloat](repeating: 0, count: n)
    for i in 1..<n { lens[i] = lens[i - 1] + hypot(p[i].x - p[i - 1].x, p[i].y - p[i - 1].y) }
    let total = max(lens[n - 1], 1e-6)
    var left: [CGPoint] = [], right: [CGPoint] = []
    for i in 0..<n {
        let a = p[max(0, i - 1)], b = p[min(n - 1, i + 1)]
        let l = max(hypot(b.x - a.x, b.y - a.y), 1e-6)
        let tx = (b.x - a.x) / l, ty = (b.y - a.y) / l
        let hw = (w0 + (w1 - w0) * lens[i] / total) * 0.5
        left.append(CGPoint(x: p[i].x - ty * hw, y: p[i].y + tx * hw))
        right.append(CGPoint(x: p[i].x + ty * hw, y: p[i].y - tx * hw))
    }
    path.addLines(between: left + right.reversed())
    path.closeSubpath()
    return path
}

func softDot(_ ctx: CGContext, _ c: CGPoint, _ radius: CGFloat, _ color: RGB, _ alpha: CGFloat) {
    let g = gradient([color.cg(alpha), color.cg(alpha * 0.45), color.cg(0)], [0, 0.5, 1])
    ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: [])
}

func blurred(_ ctx: CGContext, color: CGColor, blur: CGFloat, _ body: (CGContext) -> Void) {
    let shift: CGFloat = 8192
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: -shift, height: 0), blur: blur, color: color)
    ctx.translateBy(x: shift, y: 0)
    ctx.setFillColor(gray: 0, alpha: 1)
    ctx.setStrokeColor(gray: 0, alpha: 1)
    body(ctx)
    ctx.restoreGState()
}

func innerShadow(_ ctx: CGContext, _ blade: CGPath, _ bounds: CGRect, color: CGColor, blur: CGFloat) {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: blur, color: color)
    ctx.addRect(bounds.insetBy(dx: -bounds.width, dy: -bounds.height))
    ctx.addPath(blade)
    ctx.setFillColor(color.copy(alpha: 1)!)
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()
}

func makeGrain(size: Int, seed: UInt64, grid: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    let bytes = ctx.data!.bindMemory(to: UInt8.self, capacity: size * size)
    var rng = Rand(seed: seed)
    var coarse = [CGFloat](repeating: 0, count: (grid + 1) * (grid + 1))
    for i in coarse.indices { coarse[i] = rng.unit() }
    let scale = CGFloat(grid) / CGFloat(size)
    for y in 0..<size {
        let fy = CGFloat(y) * scale, iy = min(grid - 1, Int(fy))
        var ty = fy - CGFloat(iy); ty = ty * ty * (3 - 2 * ty)
        for x in 0..<size {
            let fx = CGFloat(x) * scale, ix = min(grid - 1, Int(fx))
            var tx = fx - CGFloat(ix); tx = tx * tx * (3 - 2 * tx)
            let r0 = coarse[iy * (grid + 1) + ix] + (coarse[iy * (grid + 1) + ix + 1] - coarse[iy * (grid + 1) + ix]) * tx
            let r1 = coarse[(iy + 1) * (grid + 1) + ix]
                + (coarse[(iy + 1) * (grid + 1) + ix + 1] - coarse[(iy + 1) * (grid + 1) + ix]) * tx
            let v = 0.5 + (r0 + (r1 - r0) * ty - 0.5) * 0.5 + (rng.unit() - 0.5) * 0.22
            bytes[y * ctx.bytesPerRow + x] = UInt8(max(0, min(255, Int(v * 255))))
        }
    }
    return ctx.makeImage()!
}

/// Paints the leaf centred in a square image of `side` pixels.
func paintLeaf(_ leaf: Leaf, side: Int, seed: UInt64) -> CGImage {
    let center = RGB(0xF5C850), mid = RGB(0xE06A28), outer = RGB(0xB2271F)
    let edge = RGB(0x561011), veinColor = RGB(0xFFE2A2), petioleColor = RGB(0x963A1B)
    var rng = Rand(seed: seed &+ 99)
    let s = CGFloat(side)
    let ctx = makeContext(side, side)
    let bounds = CGRect(x: 0, y: 0, width: s, height: s)
    let fit = s * 0.9

    var minX = CGFloat.greatestFiniteMagnitude, minY = minX, maxX = -minX, maxY = -minX
    for p in leaf.outline + leaf.petiole {
        minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y)
    }
    let k = fit / max(maxX - minX, maxY - minY)
    let ox = s / 2 - (minX + maxX) / 2 * k, oy = s / 2 - (minY + maxY) / 2 * k
    func T(_ p: Vec) -> CGPoint { CGPoint(x: ox + p.x * k, y: oy + p.y * k) }

    // Petiole
    let stem = leaf.petiole.map(T)
    ctx.setFillColor(petioleColor.cg())
    ctx.addPath(tapered(stem, w0: 0.036 * k, w1: 0.024 * k))
    ctx.fillPath()
    let end = stem[stem.count - 1], er = 0.024 * k * 0.5
    ctx.setFillColor(petioleColor.darker(0.15).cg())
    ctx.fillEllipse(in: CGRect(x: end.x - er, y: end.y - er, width: er * 2, height: er * 2))
    let hl = stem.enumerated().map { i, p -> CGPoint in
        let a = stem[max(0, i - 1)], b = stem[min(stem.count - 1, i + 1)]
        let l = max(hypot(b.x - a.x, b.y - a.y), 1e-6), off = 0.036 * k * 0.18
        return CGPoint(x: p.x - (b.y - a.y) / l * off, y: p.y + (b.x - a.x) / l * off)
    }
    ctx.setFillColor(petioleColor.lighter(0.35).cg(0.5))
    ctx.addPath(tapered(Array(hl.dropLast(2)), w0: 0.036 * k * 0.32, w1: 0.024 * k * 0.25))
    ctx.fillPath()

    let blade = CGMutablePath()
    blade.addLines(between: leaf.outline.map(T))
    blade.closeSubpath()
    let bb = blade.boundingBoxOfPath
    ctx.saveGState()
    ctx.addPath(blade)
    ctx.clip()

    // Base colour from the heart of the leaf out to the lobe tips.
    let hc = T(Vec(0, 0.12))
    var radius: CGFloat = 1
    for p in leaf.outline { let q = T(p); radius = max(radius, hypot(q.x - hc.x, q.y - hc.y)) }
    ctx.drawRadialGradient(gradient([center.cg(), mid.cg(), outer.cg()], [0, 0.4, 0.86]), startCenter: hc, startRadius: 0,
                           endCenter: hc, endRadius: radius * 0.92, options: [.drawsAfterEndLocation])
    // Mottling
    for _ in 0..<16 {
        let p = CGPoint(x: rng.range(bb.minX, bb.maxX), y: rng.range(bb.minY, bb.maxY))
        let light = rng.unit() < 0.5
        softDot(ctx, p, fit * rng.range(0.08, 0.2), light ? center.lighter(0.12) : outer.darker(0.14), rng.range(0.1, 0.22))
    }
    // Fold light
    ctx.drawLinearGradient(gradient([CGColor(srgbRed: 1, green: 0.97, blue: 0.88, alpha: 0.13),
                                     CGColor(srgbRed: 1, green: 0.97, blue: 0.88, alpha: 0.03),
                                     CGColor(srgbRed: 0.1, green: 0.03, blue: 0, alpha: 0.03),
                                     CGColor(srgbRed: 0.1, green: 0.03, blue: 0, alpha: 0.14)], [0, 0.47, 0.53, 1]),
                           start: CGPoint(x: bb.minX, y: bb.midY), end: CGPoint(x: bb.maxX, y: bb.midY), options: [])
    // Grain
    ctx.saveGState()
    ctx.setBlendMode(.softLight)
    ctx.setAlpha(0.5)
    ctx.interpolationQuality = .high
    ctx.draw(makeGrain(size: side / 2, seed: 0x6EA1, grid: 18), in: bounds)
    ctx.restoreGState()
    // Margins
    innerShadow(ctx, blade, bounds, color: edge.cg(0.5), blur: fit * 0.085)
    innerShadow(ctx, blade, bounds, color: edge.cg(0.28), blur: fit * 0.012)
    // Veins: groove, then the paler vein.
    let veinScale: CGFloat = 0.46
    for major in [false, true] {
        for (color, alpha, offset) in [(edge, CGFloat(0.16), CGFloat(fit * 0.0035)), (veinColor, major ? 0.34 : 0.24, 0)] {
            ctx.saveGState()
            ctx.setAlpha(alpha)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.translateBy(x: offset, y: -offset)
            ctx.setFillColor(color.cg())
            for v in leaf.veins where v.major == major {
                ctx.addPath(tapered(v.pts.map(T), w0: v.w0 * k * veinScale, w1: max(v.w1 * k * veinScale, 1)))
                ctx.fillPath()
            }
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
    }
    // Crisp darker rim
    innerShadow(ctx, blade, bounds, color: edge.cg(0.65), blur: max(1.2, fit * 0.004))
    ctx.restoreGState()
    return ctx.makeImage()!
}

// MARK: - Icon

/// macOS-style squircle: a superellipse-cornered rounded square (~22.5% corner radius).
func squircle(_ rect: CGRect, radiusFraction: CGFloat = 0.225) -> CGPath {
    let path = CGMutablePath()
    let r = rect.width * radiusFraction
    // Continuous corners: each corner blends into the edge over ~1.3 r with a superellipse-like cubic.
    let a = r * 1.3
    let c: CGFloat = 0.36   // control handle as a fraction of a (0.55 would be circular-ish)
    let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
    path.move(to: CGPoint(x: minX + a, y: minY))
    path.addLine(to: CGPoint(x: maxX - a, y: minY))
    path.addCurve(to: CGPoint(x: maxX, y: minY + a), control1: CGPoint(x: maxX - a * c, y: minY),
                  control2: CGPoint(x: maxX, y: minY + a * c))
    path.addLine(to: CGPoint(x: maxX, y: maxY - a))
    path.addCurve(to: CGPoint(x: maxX - a, y: maxY), control1: CGPoint(x: maxX, y: maxY - a * c),
                  control2: CGPoint(x: maxX - a * c, y: maxY))
    path.addLine(to: CGPoint(x: minX + a, y: maxY))
    path.addCurve(to: CGPoint(x: minX, y: maxY - a), control1: CGPoint(x: minX + a * c, y: maxY),
                  control2: CGPoint(x: minX, y: maxY - a * c))
    path.addLine(to: CGPoint(x: minX, y: minY + a))
    path.addCurve(to: CGPoint(x: minX + a, y: minY), control1: CGPoint(x: minX, y: minY + a * c),
                  control2: CGPoint(x: minX + a * c, y: minY))
    path.closeSubpath()
    return path
}

func renderIcon(leafSeed: UInt64) -> CGImage {
    let size = 1024
    let S = CGFloat(size)
    let ctx = makeContext(size, size)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)   // standard ~10% margin
    let shape = squircle(body)

    // Soft drop shadow of the tile itself.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: CGColor(srgbRed: 0.05, green: 0.01, blue: 0.03, alpha: 0.42))
    ctx.addPath(shape)
    ctx.setFillColor(RGB(0x2A1521).cg())
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    // Dusk: deep plum overhead warming to amber at the horizon.
    ctx.drawLinearGradient(gradient([RGB(0x8C4227).cg(), RGB(0x5E2527).cg(), RGB(0x371526).cg(), RGB(0x200D1A).cg()],
                                    [0, 0.28, 0.6, 1]),
                           start: CGPoint(x: S / 2, y: body.minY), end: CGPoint(x: S / 2, y: body.maxY), options: [])
    // Low sun glow.
    let glow = CGPoint(x: S * 0.5, y: body.minY + 60)
    ctx.drawRadialGradient(gradient([RGB(0xF2A54A).cg(0.42), RGB(0xE08A3A).cg(0.12), RGB(0xE08A3A).cg(0)], [0, 0.45, 1]),
                           startCenter: glow, startRadius: 0, endCenter: glow, endRadius: 560, options: [])
    // Gentle vignette.
    let mid = CGPoint(x: S / 2, y: S / 2)
    ctx.drawRadialGradient(gradient([RGB(0x000000).cg(0), RGB(0x0A0308).cg(0.32)], [0.55, 1]),
                           startCenter: mid, startRadius: 0, endCenter: mid, endRadius: 640, options: [.drawsAfterEndLocation])
    // Fine grain against banding.
    ctx.saveGState()
    ctx.setBlendMode(.softLight)
    ctx.setAlpha(0.22)
    ctx.draw(makeGrain(size: 1024, seed: 0xD05C, grid: 6), in: CGRect(x: 0, y: 0, width: S, height: S))
    ctx.restoreGState()

    // The leaf, tilted as if drifting, with a soft shadow on the dusk behind it.
    let leafSide = 700
    let leafImage = paintLeaf(sugarMaple(seed: leafSeed), side: leafSide, seed: leafSeed)
    ctx.saveGState()
    ctx.translateBy(x: S / 2 + 6, y: S / 2 + 4)
    ctx.rotate(by: -0.2)
    ctx.setShadow(offset: CGSize(width: 14, height: -26), blur: 34, color: CGColor(srgbRed: 0.06, green: 0.01, blue: 0.03, alpha: 0.55))
    let L = CGFloat(leafSide)
    ctx.draw(leafImage, in: CGRect(x: -L / 2, y: -L / 2, width: L, height: L))
    ctx.restoreGState()

    // Hairline highlight on the upper rim, faint shade on the lower rim.
    ctx.addPath(shape)
    ctx.setLineWidth(3)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([RGB(0xFFE6C8).cg(0.16), RGB(0xFFE6C8).cg(0), RGB(0x000000).cg(0), RGB(0x000000).cg(0.18)],
                                    [0, 0.35, 0.7, 1]),
                           start: CGPoint(x: S / 2, y: body.maxY), end: CGPoint(x: S / 2, y: body.minY), options: [])
    ctx.restoreGState()
    return ctx.makeImage()!
}

func resized(_ image: CGImage, to px: Int) -> CGImage {
    // Halve step by step for clean small sizes.
    var current = image
    while current.width / 2 >= px {
        let w = current.width / 2
        let c = makeContext(w, w)
        c.draw(current, in: CGRect(x: 0, y: 0, width: w, height: w))
        current = c.makeImage()!
    }
    if current.width != px {
        let c = makeContext(px, px)
        c.draw(current, in: CGRect(x: 0, y: 0, width: px, height: px))
        current = c.makeImage()!
    }
    return current
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "make-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot write \(url.path)"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "make-icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot finalize \(url.path)"])
    }
}

// MARK: - Main

let repoRoot = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
let output = repoRoot.appendingPathComponent("Resources/AppIcon.icns")
let fm = FileManager.default
let work = fm.temporaryDirectory.appendingPathComponent("rustle-icon-\(ProcessInfo.processInfo.processIdentifier)")
let iconset = work.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: work)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: work) }

let master = renderIcon(leafSeed: 0x5EED_1EAF &+ 4 &* 0x9E37_79B9 &+ 77)
if CommandLine.arguments.count > 1 {
    try writePNG(master, to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
for base in [16, 32, 128, 256, 512] {
    try writePNG(resized(master, to: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try writePNG(resized(master, to: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed with status \(iconutil.terminationStatus)\n".data(using: .utf8)!)
    exit(1)
}
print("Wrote \(output.path)")
