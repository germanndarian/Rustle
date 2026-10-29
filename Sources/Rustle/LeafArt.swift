import CoreGraphics
import Foundation

// MARK: - Public API

enum LeafSpecies: CaseIterable {
    case maple, oak, birch, beech, ginkgo, sweetgum
}

/// One leaf drawing inside the sprite sheet.
struct LeafCell {
    /// Cell bounds in SpriteKit unit texture coordinates (0...1, origin bottom-left),
    /// ready for `SKTexture(rect:in:)`.
    let rect: CGRect
    let species: LeafSpecies
    /// Fraction of the square cell the leaf actually covers (0...1), used for hit radius.
    let coverage: CGFloat
}

struct LeafSheet {
    let image: CGImage
    let cells: [LeafCell]
    /// Side of one square cell in points. Sprites are drawn at this size times their scale.
    let cellPointSize: CGFloat
}

enum LeafArt {
    /// Renders every leaf variant into one sprite sheet so SpriteKit can batch them in a single draw.
    /// Leaves point up (stem at the bottom), centered in square cells.
    static func makeSheet(cellPointSize: CGFloat = 40, scale: CGFloat = 2) -> LeafSheet {
        let variants = catalog()
        let scale = max(scale, 0.5)
        let cellPx = max(24, Int((cellPointSize * scale).rounded()))
        let cols = Int(Double(variants.count).squareRoot().rounded(.up))
        let rows = (variants.count + cols - 1) / cols
        let width = cols * cellPx
        let height = rows * cellPx
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high

        let side = CGFloat(cellPx)
        let w = CGFloat(width)
        let h = CGFloat(height)
        let grain = makeGrain(size: cellPx * 2)
        var cells: [LeafCell] = []
        cells.reserveCapacity(variants.count)
        for (i, variant) in variants.enumerated() {
            let col = i % cols
            let row = i / cols
            // Row 0 is the top row of the image; CGContext's origin is bottom-left like SpriteKit's.
            let rect = CGRect(x: CGFloat(col) * side, y: CGFloat(rows - 1 - row) * side, width: side, height: side)
            let coverage = paint(variant, in: rect, ctx: ctx, grain: grain)
            cells.append(LeafCell(rect: CGRect(x: rect.minX / w, y: rect.minY / h, width: side / w, height: side / h),
                                  species: variant.species, coverage: coverage))
        }
        return LeafSheet(image: ctx.makeImage()!, cells: cells, cellPointSize: side / scale)
    }
}

// MARK: - Implementation

extension LeafArt {

    // MARK: Math helpers

    fileprivate struct Vec {
        var x: CGFloat
        var y: CGFloat
        init(_ x: CGFloat, _ y: CGFloat) { self.x = x; self.y = y }
        static func + (a: Vec, b: Vec) -> Vec { Vec(a.x + b.x, a.y + b.y) }
        static func - (a: Vec, b: Vec) -> Vec { Vec(a.x - b.x, a.y - b.y) }
        static func * (a: Vec, k: CGFloat) -> Vec { Vec(a.x * k, a.y * k) }
        var length: CGFloat { (x * x + y * y).squareRoot() }
        var normalized: Vec { let l = max(length, 1e-9); return Vec(x / l, y / l) }
        func rotated(_ rad: CGFloat) -> Vec {
            let c = cos(rad), s = sin(rad)
            return Vec(x * c - y * s, x * s + y * c)
        }
        func dot(_ o: Vec) -> CGFloat { x * o.x + y * o.y }
    }

    /// SplitMix64: tiny, fast and fully deterministic, so the sheet is identical every launch.
    fileprivate struct Rand {
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
        mutating func chance(_ p: CGFloat) -> Bool { unit() < p }
    }

    fileprivate struct RGB {
        var r: CGFloat
        var g: CGFloat
        var b: CGFloat
        init(_ hex: UInt32) {
            r = CGFloat((hex >> 16) & 0xFF) / 255
            g = CGFloat((hex >> 8) & 0xFF) / 255
            b = CGFloat(hex & 0xFF) / 255
        }
        init(r: CGFloat, g: CGFloat, b: CGFloat) { self.r = r; self.g = g; self.b = b }
        func mix(_ o: RGB, _ t: CGFloat) -> RGB {
            RGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t)
        }
        /// Toward a warm cream rather than pure white, so highlights stay autumnal.
        func lighter(_ t: CGFloat) -> RGB { mix(RGB(r: 1, g: 0.97, b: 0.86), t) }
        func darker(_ t: CGFloat) -> RGB { mix(RGB(r: 0.10, g: 0.04, b: 0.02), t) }
        func cg(_ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    }

    // MARK: Palettes

    fileprivate struct Palette {
        var center: RGB
        var mid: RGB
        var outer: RGB
        var edge: RGB
        var vein: RGB
        var petiole: RGB
        var veinAlpha: CGFloat = 0.42
        /// Residual green along the main veins of a leaf that is still turning.
        var chlorophyll: RGB? = nil
        /// 0...1: how parched the leaf is (stronger browned margin).
        var dry: CGFloat = 0
    }

    fileprivate static var golden: Palette {
        Palette(center: RGB(0xF7D769), mid: RGB(0xF0BD3C), outer: RGB(0xE19A25),
                edge: RGB(0x8C5211), vein: RGB(0xFFF2BA), petiole: RGB(0xB08A30))
    }
    fileprivate static var amber: Palette {
        Palette(center: RGB(0xF5BF55), mid: RGB(0xE69A30), outer: RGB(0xCD7222),
                edge: RGB(0x733A0F), vein: RGB(0xFFE2A4), petiole: RGB(0x9A5C20))
    }
    fileprivate static var burntOrange: Palette {
        Palette(center: RGB(0xF1A447), mid: RGB(0xDE7428), outer: RGB(0xBC4E1B),
                edge: RGB(0x62250C), vein: RGB(0xFFD490), petiole: RGB(0x8A3A16))
    }
    fileprivate static var scarlet: Palette {
        Palette(center: RGB(0xEA5D2E), mid: RGB(0xD33D23), outer: RGB(0xB0261C),
                edge: RGB(0x530D0B), vein: RGB(0xFFB888), petiole: RGB(0x8A2015), veinAlpha: 0.38)
    }
    fileprivate static var crimson: Palette {
        Palette(center: RGB(0xCA3530), mid: RGB(0xA82228), outer: RGB(0x82171F),
                edge: RGB(0x36060F), vein: RGB(0xF29A80), petiole: RGB(0x6A1518), veinAlpha: 0.36)
    }
    fileprivate static var maroon: Palette {
        Palette(center: RGB(0xA63A33), mid: RGB(0x80292B), outer: RGB(0x5E1E23),
                edge: RGB(0x24080C), vein: RGB(0xDC8A72), petiole: RGB(0x4E1A18), veinAlpha: 0.34)
    }
    fileprivate static var wine: Palette {
        Palette(center: RGB(0xA2404F), mid: RGB(0x7C2C40), outer: RGB(0x5A1F33),
                edge: RGB(0x22070F), vein: RGB(0xD08E98), petiole: RGB(0x4A1A22), veinAlpha: 0.32)
    }
    fileprivate static var russet: Palette {
        Palette(center: RGB(0xC77131), mid: RGB(0xA75520), outer: RGB(0x874018),
                edge: RGB(0x3E1F0A), vein: RGB(0xEFBC8A), petiole: RGB(0x6E3A18), dry: 0.2)
    }
    fileprivate static var oakBrown: Palette {
        Palette(center: RGB(0xA2723F), mid: RGB(0x84582F), outer: RGB(0x664224),
                edge: RGB(0x2E1E0E), vein: RGB(0xDAB685), petiole: RGB(0x5A3A1E), veinAlpha: 0.36, dry: 0.5)
    }
    fileprivate static var tan: Palette {
        Palette(center: RGB(0xD9B983), mid: RGB(0xC29A62), outer: RGB(0xA27A48),
                edge: RGB(0x553E22), vein: RGB(0xF3E0BA), petiole: RGB(0x8A6A42), veinAlpha: 0.38, dry: 0.7)
    }
    fileprivate static var bronze: Palette {
        Palette(center: RGB(0xD69140), mid: RGB(0xBA722D), outer: RGB(0x965322),
                edge: RGB(0x48270E), vein: RGB(0xF4CE96), petiole: RGB(0x7A4E22), dry: 0.25)
    }
    fileprivate static var oakWine: Palette {
        Palette(center: RGB(0xA84C3B), mid: RGB(0x85362C), outer: RGB(0x652822),
                edge: RGB(0x2C0E0C), vein: RGB(0xE2A68E), petiole: RGB(0x5A2A1C), veinAlpha: 0.34, dry: 0.2)
    }
    fileprivate static var turningGold: Palette {
        Palette(center: RGB(0xB6B648), mid: RGB(0xE7C445), outer: RGB(0xEBA12D),
                edge: RGB(0x875915), vein: RGB(0xF2F3AE), petiole: RGB(0x8E9A3E),
                chlorophyll: RGB(0x98AC3C))
    }
    fileprivate static var turningOrange: Palette {
        Palette(center: RGB(0xC6B644), mid: RGB(0xE8A734), outer: RGB(0xD66325),
                edge: RGB(0x67290E), vein: RGB(0xF7EAA8), petiole: RGB(0x8C7A2E),
                chlorophyll: RGB(0xA6AE3C))
    }
    fileprivate static var turningRed: Palette {
        Palette(center: RGB(0xEEBA42), mid: RGB(0xE3812E), outer: RGB(0xC73523),
                edge: RGB(0x561011), vein: RGB(0xFFDE9A), petiole: RGB(0x9A3A1A))
    }
    fileprivate static var ginkgoGold: Palette {
        Palette(center: RGB(0xF9DF69), mid: RGB(0xF3C940), outer: RGB(0xE6AB2B),
                edge: RGB(0x986816), vein: RGB(0xFFF5C6), petiole: RGB(0xA08C3C), veinAlpha: 0.34)
    }
    fileprivate static var butter: Palette {
        Palette(center: RGB(0xFBE88E), mid: RGB(0xF6D55D), outer: RGB(0xECBC3E),
                edge: RGB(0xA47A22), vein: RGB(0xFFF9DA), petiole: RGB(0xB09A4A), veinAlpha: 0.34)
    }
    fileprivate static var aspenGold: Palette {
        Palette(center: RGB(0xF8DD5B), mid: RGB(0xF1C538), outer: RGB(0xE2A527),
                edge: RGB(0x8A5C12), vein: RGB(0xFFF3B6), petiole: RGB(0xA88A30))
    }

    // MARK: Catalog

    fileprivate enum Form {
        case sugarMaple, redMaple, japaneseMaple, sweetgum
        case englishOak, whiteOak, birch, aspen, beech, elm, ginkgo, ginkgoBilobed
    }

    fileprivate enum Mark { case speckles, tarSpots, blotch }

    fileprivate struct Variant {
        let species: LeafSpecies
        let form: Form
        let palette: Palette
        let marks: [Mark]
        let seed: UInt64
    }

    fileprivate static func catalog() -> [Variant] {
        var list: [Variant] = []
        func add(_ species: LeafSpecies, _ form: Form, _ palette: Palette, _ marks: [Mark] = []) {
            let seed = 0x5EED_1EAF &+ UInt64(list.count) &* 0x9E37_79B9
            list.append(Variant(species: species, form: form, palette: palette, marks: marks, seed: seed))
        }
        // Maple: the full red–orange–yellow range.
        add(.maple, .sugarMaple, golden, [.tarSpots])
        add(.maple, .sugarMaple, amber, [.speckles])
        add(.maple, .sugarMaple, burntOrange)
        add(.maple, .sugarMaple, scarlet)
        add(.maple, .sugarMaple, turningRed)
        add(.maple, .sugarMaple, crimson)
        add(.maple, .sugarMaple, turningOrange, [.speckles])
        add(.maple, .redMaple, scarlet)
        add(.maple, .redMaple, turningRed, [.speckles])
        add(.maple, .redMaple, maroon)
        add(.maple, .japaneseMaple, scarlet)
        add(.maple, .japaneseMaple, crimson)
        add(.maple, .japaneseMaple, burntOrange)
        // Oak: russet, brown, tan, amber.
        add(.oak, .englishOak, russet, [.blotch])
        add(.oak, .englishOak, oakBrown, [.speckles])
        add(.oak, .whiteOak, oakWine)
        add(.oak, .whiteOak, tan, [.speckles])
        add(.oak, .englishOak, bronze, [.blotch])
        // Birch / aspen.
        add(.birch, .birch, golden, [.speckles])
        add(.birch, .birch, turningGold)
        add(.birch, .aspen, aspenGold, [.speckles])
        add(.birch, .aspen, amber, [.blotch])
        add(.birch, .birch, tan, [.speckles])
        // Beech / elm.
        add(.beech, .beech, bronze)
        add(.beech, .beech, russet, [.blotch])
        add(.beech, .elm, golden, [.speckles])
        add(.beech, .elm, turningGold)
        // Ginkgo: mostly golden.
        add(.ginkgo, .ginkgo, ginkgoGold)
        add(.ginkgo, .ginkgoBilobed, ginkgoGold)
        add(.ginkgo, .ginkgo, butter)
        add(.ginkgo, .ginkgo, turningGold)
        // Sweetgum: purple-maroon through scarlet to gold.
        add(.sweetgum, .sweetgum, wine)
        add(.sweetgum, .sweetgum, scarlet)
        add(.sweetgum, .sweetgum, burntOrange)
        add(.sweetgum, .sweetgum, amber, [.speckles])
        add(.sweetgum, .sweetgum, turningRed)
        return list
    }

    // MARK: Geometry model (leaf units: petiole junction near the origin, tip near (0, 1))

    fileprivate enum KeyKind { case smooth, tip, corner }

    /// A control point of the leaf outline. `serr` scales the margin teeth around it.
    fileprivate struct Key {
        var p: Vec
        var kind: KeyKind
        var serr: CGFloat
        init(_ x: CGFloat, _ y: CGFloat, _ kind: KeyKind = .smooth, _ serr: CGFloat = 1) {
            p = Vec(x, y); self.kind = kind; self.serr = serr
        }
        init(_ p: Vec, _ kind: KeyKind, _ serr: CGFloat) { self.p = p; self.kind = kind; self.serr = serr }
        var mirrored: Key { Key(Vec(-p.x, p.y), kind, serr) }
    }

    fileprivate enum Teeth { case none, serrate, double, crenate, wavy }

    fileprivate struct Margin {
        var teeth: Teeth = .none
        var amplitude: CGFloat = 0
        var wavelength: CGFloat = 0.05
        /// Low-frequency irregularity so no two edges are mathematically clean.
        var wobble: CGFloat = 0.004
    }

    fileprivate struct Vein {
        var pts: [Vec]
        var w0: CGFloat
        var w1: CGFloat
        var major: Bool
    }

    /// A vein described by origin and direction; its length is found by hitting the outline.
    fileprivate struct Ray {
        var origin: Vec
        var dir: Vec
        var reach: CGFloat
        var w0: CGFloat
        var w1: CGFloat
        var curl: CGFloat
        var major: Bool
    }

    fileprivate struct Draft {
        var keys: [Key] = []
        var veins: [Vein] = []
        var rays: [Ray] = []
    }

    fileprivate struct Geometry {
        var outline: [Vec] = []
        var veins: [Vein] = []
        var petiole: [Vec] = []
        var petioleW0: CGFloat = 0.036
        var petioleW1: CGFloat = 0.024
        var heart = Vec(0, 0.3)
        /// x radius / y radius of the elliptical colour gradient.
        var gradAspect: CGFloat = 1
        var veinBoost: CGFloat = 1

        mutating func warp(bend: CGFloat, asym: CGFloat) {
            func f(_ p: Vec) -> Vec {
                let sx: CGFloat = p.x > 0 ? 1 + asym : 1 - asym
                let yy = max(p.y, 0)
                return Vec(p.x * sx + bend * yy * yy, p.y)
            }
            outline = outline.map(f)
            petiole = petiole.map(f)
            heart = f(heart)
            for i in veins.indices { veins[i].pts = veins[i].pts.map(f) }
        }
    }

    // MARK: Outline construction

    /// Centripetal Catmull–Rom (Barry–Goldman), which never overshoots into loops.
    fileprivate static func catmullRom(_ p0: Vec, _ p1: Vec, _ p2: Vec, _ p3: Vec, _ t: CGFloat) -> Vec {
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

    fileprivate static func saw(_ u: CGFloat) -> CGFloat {
        let k: CGFloat = 0.78
        return u < k ? pow(u / k, 0.9) : (1 - u) / (1 - k)
    }

    fileprivate static func toothProfile(_ teeth: Teeth, _ u: CGFloat) -> CGFloat {
        switch teeth {
        case .none:
            return 0
        case .serrate:
            return saw(u)
        case .double:
            var v = u * 3
            v -= v.rounded(.down)
            return 0.72 * saw(u) + 0.3 * saw(v)
        case .crenate:
            return pow(sin(.pi * u), 0.55)
        case .wavy:
            return 0.5 - 0.5 * cos(2 * .pi * u)
        }
    }

    /// Splines the keys into a dense closed polygon, then cuts the margin teeth along the normal.
    /// Teeth lean toward the nearest tip key, as real serrations point toward the apex.
    fileprivate static func outline(_ keys: [Key], _ margin: Margin, _ rng: inout Rand) -> [Vec] {
        let n = keys.count
        var pts: [Vec] = []
        var amp: [CGFloat] = []
        var tipIdx: [Int] = []
        let step: CGFloat = 0.003
        for i in 0..<n {
            let k1 = keys[i]
            let k2 = keys[(i + 1) % n]
            let p1 = k1.p, p2 = k2.p
            let p0 = k1.kind == .smooth ? keys[(i + n - 1) % n].p : p1 * 2 - p2
            let p3 = k2.kind == .smooth ? keys[(i + 2) % n].p : p2 * 2 - p1
            if k1.kind == .tip { tipIdx.append(pts.count) }
            let m = max(2, Int(((p2 - p1).length / step).rounded(.up)))
            for j in 0..<m {
                let t = CGFloat(j) / CGFloat(m)
                pts.append(catmullRom(p0, p1, p2, p3, t))
                amp.append(k1.serr + (k2.serr - k1.serr) * t)
            }
        }

        let count = pts.count
        var s = [CGFloat](repeating: 0, count: count)
        for i in 1..<count { s[i] = s[i - 1] + (pts[i] - pts[i - 1]).length }
        let total = s[count - 1] + (pts[0] - pts[count - 1]).length
        var area: CGFloat = 0
        for i in 0..<count {
            let a = pts[i], b = pts[(i + 1) % count]
            area += a.x * b.y - b.x * a.y
        }
        let orient: CGFloat = area >= 0 ? 1 : -1
        let tipS = tipIdx.map { s[$0] }
        let cycles1 = max(1, (total / 0.45).rounded())
        let cycles2 = max(2, (total / 0.16).rounded())
        let ph1 = rng.range(0, 2 * .pi)
        let ph2 = rng.range(0, 2 * .pi)
        let phase0 = rng.unit()

        var out: [Vec] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let prev = pts[(i + count - 1) % count]
            let next = pts[(i + 1) % count]
            let tan = (next - prev).normalized
            let nrm = Vec(tan.y * orient, -tan.x * orient)
            var d: CGFloat = 0
            if margin.teeth != .none && amp[i] > 0.001 {
                var ahead = CGFloat.greatestFiniteMagnitude
                var behind = CGFloat.greatestFiniteMagnitude
                for ts in tipS {
                    var a = ts - s[i]
                    if a < 0 { a += total }
                    var b = s[i] - ts
                    if b < 0 { b += total }
                    ahead = min(ahead, a)
                    behind = min(behind, b)
                }
                var u = s[i] / margin.wavelength + phase0
                u -= u.rounded(.down)
                if behind < ahead { u = 1 - u }
                d = margin.amplitude * amp[i] * toothProfile(margin.teeth, u)
            }
            let a1 = 2 * CGFloat.pi * cycles1 * s[i] / total + ph1
            let a2 = 2 * CGFloat.pi * cycles2 * s[i] / total + ph2
            let w = margin.wobble * (0.6 * sin(a1) + 0.4 * sin(a2))
            out.append(pts[i] + nrm * (d + w))
        }
        return out
    }

    /// Quadratic curve from a to b; `bend` offsets the control point along the left normal (fraction of length).
    fileprivate static func curve(_ a: Vec, _ b: Vec, bend: CGFloat, segments: Int = 10) -> [Vec] {
        let d = b - a
        let c = (a + b) * 0.5 + Vec(-d.y, d.x) * bend
        var out: [Vec] = []
        out.reserveCapacity(segments + 1)
        for i in 0...segments {
            let t = CGFloat(i) / CGFloat(segments)
            let u = 1 - t
            out.append(a * (u * u) + c * (2 * u * t) + b * (t * t))
        }
        return out
    }

    /// Distance along the ray to the first crossing of the closed polygon.
    fileprivate static func hit(_ o: Vec, _ d: Vec, _ poly: [Vec]) -> CGFloat? {
        var best = CGFloat.greatestFiniteMagnitude
        let n = poly.count
        for i in 0..<n {
            let a = poly[i]
            let e = poly[(i + 1) % n] - a
            let den = d.x * e.y - d.y * e.x
            if abs(den) < 1e-12 { continue }
            let w = a - o
            let t = (w.x * e.y - w.y * e.x) / den
            let s = (w.x * d.y - w.y * d.x) / den
            if t > 1e-5 && s >= 0 && s <= 1 && t < best { best = t }
        }
        return best < .greatestFiniteMagnitude ? best : nil
    }

    fileprivate static func resolve(_ rays: [Ray], in poly: [Vec]) -> [Vein] {
        var out: [Vein] = []
        for r in rays {
            guard let d = hit(r.origin, r.dir, poly) else { continue }
            let len = d * r.reach
            if len < 0.03 { continue }
            let end = r.origin + r.dir * len
            // Bow toward the base side so the vein arches toward the apex near the margin.
            let side: CGFloat = r.dir.x >= 0 ? -1 : 1
            out.append(Vein(pts: curve(r.origin, end, bend: side * r.curl), w0: r.w0, w1: r.w1, major: r.major))
        }
        return out
    }

    fileprivate static func midrib(_ top: CGFloat, w0: CGFloat = 0.026) -> Vein {
        Vein(pts: curve(Vec(0, 0), Vec(0, top), bend: 0, segments: 16), w0: w0, w1: 0.005, major: true)
    }

    fileprivate static func pinnateRays(_ ts: [CGFloat], angle: CGFloat, reach: CGFloat, curl: CGFloat,
                                        w0: CGFloat, w1: CGFloat, leftOffset: CGFloat, _ rng: inout Rand) -> [Ray] {
        var rays: [Ray] = []
        let a = angle * .pi / 180
        for t in ts {
            for side in [CGFloat(1), CGFloat(-1)] {
                let tt = t + (side < 0 ? leftOffset : 0) + rng.range(-0.01, 0.01)
                let aa = a + rng.range(-0.05, 0.05)
                rays.append(Ray(origin: Vec(0, tt), dir: Vec(side * sin(aa), cos(aa)), reach: reach,
                                w0: w0, w1: w1, curl: curl, major: false))
            }
        }
        return rays
    }

    /// Base corner, right half (bottom to top), tip, then the (mirrored) left half back down.
    fileprivate static func bilateral(base: Key, right: [Key], tip: Key, left: [Key]? = nil,
                                      jitter: CGFloat, _ rng: inout Rand) -> [Key] {
        var keys = [base]
        for k in right {
            let x = k.p.x * (1 + rng.range(-jitter, jitter))
            let y = k.p.y + rng.range(-jitter, jitter) * 0.05
            keys.append(Key(Vec(x, y), k.kind, k.serr))
        }
        keys.append(tip)
        for k in (left ?? right).reversed() {
            let x = k.p.x * (1 + rng.range(-jitter, jitter))
            let y = k.p.y + rng.range(-jitter, jitter) * 0.05
            keys.append(Key(Vec(-x, y), k.kind, k.serr))
        }
        return keys
    }

    fileprivate static func finish(_ d: Draft, margin: Margin, petiole: (length: CGFloat, angle: CGFloat),
                                   heart: Vec, aspect: CGFloat, _ rng: inout Rand) -> Geometry {
        var g = Geometry()
        g.outline = outline(d.keys, margin, &rng)
        g.veins = d.veins + resolve(d.rays, in: g.outline)
        let th = petiole.angle * .pi / 180
        let start = Vec(0, 0.035)
        let len = petiole.length + 0.035
        let end = start + Vec(sin(th) * len, -cos(th) * len)
        g.petiole = curve(start, end, bend: rng.range(-0.22, 0.22), segments: 14)
        g.heart = heart
        g.gradAspect = aspect
        return g
    }

    // MARK: Palmate leaves (maple, sweetgum)

    fileprivate struct LobeTemplate {
        /// +x half of the lobe from just below the tip down toward the sinus (local units, tip at (0, 1)).
        var toothed: [Key]
        var plain: [Key]
    }

    fileprivate struct Lobe {
        var angle: CGFloat      // degrees from vertical, positive to the right
        var length: CGFloat
        var template: LobeTemplate
        var plusTeeth: Bool
        var minusTeeth: Bool
    }

    /// Lobes radiate from the petiole junction; `lobes` run from the lower right, over the top, to the lower left.
    fileprivate static func palmate(_ lobes: [Lobe], sinus: [CGFloat], base: CGFloat, toothJitter: CGFloat,
                                    sideVeins: [CGFloat], sideAngle: CGFloat, _ rng: inout Rand) -> Draft {
        var draft = Draft()
        var lists: [[Key]] = []
        for lobe in lobes {
            let th = lobe.angle * .pi / 180
            let c = cos(th), s = sin(th), len = lobe.length
            let axis = Vec(s, c)
            func place(_ q: Vec) -> Vec { Vec((q.x * c + q.y * s) * len, (-q.x * s + q.y * c) * len) }
            var keys: [Key] = []
            var teethTips: [Vec] = []
            let plus = lobe.plusTeeth ? lobe.template.toothed : lobe.template.plain
            let minus = lobe.minusTeeth ? lobe.template.toothed : lobe.template.plain
            for k in plus.reversed() {
                let j: CGFloat = k.kind == .tip ? toothJitter : 0.05
                let q = Vec(k.p.x * (1 + rng.range(-j, j)), k.p.y + rng.range(-j, j) * 0.05)
                let p = place(q)
                if k.kind == .tip { teethTips.append(p) }
                keys.append(Key(p, k.kind, k.serr))
            }
            let tip = place(Vec(0, 1))
            keys.append(Key(tip, .tip, 0))
            for k in minus {
                let j: CGFloat = k.kind == .tip ? toothJitter : 0.05
                let q = Vec(-k.p.x * (1 + rng.range(-j, j)), k.p.y + rng.range(-j, j) * 0.05)
                let p = place(q)
                if k.kind == .tip { teethTips.append(p) }
                keys.append(Key(p, k.kind, k.serr))
            }
            lists.append(keys)

            let w0 = 0.027 * len.squareRoot()
            draft.veins.append(Vein(pts: curve(Vec(0, 0), tip * 0.95, bend: rng.range(-0.035, 0.035)),
                                    w0: w0, w1: 0.005, major: true))
            for t in teethTips {
                let proj = max(0.2 * len, t.dot(axis) * 0.6)
                let a = axis * proj
                let b = a + (t - a) * 0.88
                let bend: CGFloat = (t - a).x * axis.y - (t - a).y * axis.x > 0 ? 0.08 : -0.08
                draft.veins.append(Vein(pts: curve(a, b, bend: bend), w0: 0.013, w1: 0.003, major: false))
            }
            for f in sideVeins {
                for sgn in [CGFloat(1), CGFloat(-1)] {
                    let o = axis * (f * len)
                    let dir = axis.rotated(sgn * sideAngle * .pi / 180)
                    draft.rays.append(Ray(origin: o, dir: dir, reach: 0.82, w0: 0.010, w1: 0.0025,
                                          curl: 0.06, major: false))
                }
            }
        }
        var all: [Key] = []
        let first = lists[0][0].p
        let last = lists[lists.count - 1][lists[lists.count - 1].count - 1].p
        all.append(Key((first + last) * (0.5 * base), .corner, 0))
        for (i, list) in lists.enumerated() {
            if i > 0 {
                let a = lists[i - 1][lists[i - 1].count - 1].p
                let b = list[0].p
                all.append(Key((a + b) * (0.5 * sinus[i - 1]), .smooth, 0))
            }
            all += list
        }
        draft.keys = all
        return draft
    }

    fileprivate static func sugarMaple(_ r: inout Rand) -> Geometry {
        let main = LobeTemplate(
            toothed: [Key(0.072, 0.845, .smooth, 0.6), Key(0.084, 0.772, .smooth, 0.3), Key(0.19, 0.80, .tip, 0),
                      Key(0.152, 0.70, .smooth, 0.3), Key(0.29, 0.665, .tip, 0), Key(0.19, 0.565),
                      Key(0.168, 0.50, .smooth, 0.4)],
            plain: [Key(0.085, 0.83), Key(0.15, 0.70), Key(0.18, 0.585), Key(0.168, 0.50, .smooth, 0.4)])
        let basal = LobeTemplate(
            toothed: [Key(0.08, 0.80), Key(0.10, 0.70, .smooth, 0.3), Key(0.24, 0.68, .tip, 0),
                      Key(0.17, 0.56), Key(0.15, 0.48, .smooth, 0.4)],
            plain: [Key(0.09, 0.80), Key(0.16, 0.64), Key(0.15, 0.48, .smooth, 0.4)])
        let side = r.range(46, 54)
        let low = r.range(106, 118)
        var lobes: [Lobe] = []
        lobes.append(Lobe(angle: low + r.range(-4, 4), length: r.jitter(0.44, 0.08), template: basal,
                          plusTeeth: false, minusTeeth: true))
        lobes.append(Lobe(angle: side + r.range(-3, 3), length: r.jitter(0.86, 0.05), template: main,
                          plusTeeth: true, minusTeeth: true))
        lobes.append(Lobe(angle: r.range(-3, 3), length: 1, template: main, plusTeeth: true, minusTeeth: true))
        lobes.append(Lobe(angle: -side + r.range(-3, 3), length: r.jitter(0.86, 0.05), template: main,
                          plusTeeth: true, minusTeeth: true))
        lobes.append(Lobe(angle: -low + r.range(-4, 4), length: r.jitter(0.44, 0.08), template: basal,
                          plusTeeth: true, minusTeeth: false))
        let sinus = [r.jitter(0.80, 0.05), r.jitter(0.74, 0.05), r.jitter(0.74, 0.05), r.jitter(0.80, 0.05)]
        let d = palmate(lobes, sinus: sinus, base: 0.3, toothJitter: 0.22, sideVeins: [0.36], sideAngle: 55, &r)
        let pet = (length: r.range(0.15, 0.2), angle: r.range(-14, 14))
        return finish(d, margin: Margin(teeth: .none, wobble: 0.0045), petiole: pet,
                      heart: Vec(0, 0.12), aspect: 1, &r)
    }

    fileprivate static func redMaple(_ r: inout Rand) -> Geometry {
        let main = LobeTemplate(
            toothed: [Key(0.085, 0.84), Key(0.13, 0.765, .smooth, 0.6), Key(0.205, 0.745, .tip, 0.3),
                      Key(0.195, 0.645), Key(0.235, 0.57), Key(0.21, 0.52, .smooth, 0.6)],
            plain: [Key(0.10, 0.80), Key(0.18, 0.66), Key(0.22, 0.56), Key(0.21, 0.52, .smooth, 0.6)])
        let side = r.range(50, 56)
        let low = r.range(100, 110)
        var lobes: [Lobe] = []
        lobes.append(Lobe(angle: low, length: r.jitter(0.32, 0.1), template: main, plusTeeth: false, minusTeeth: false))
        lobes.append(Lobe(angle: side + r.range(-3, 3), length: r.jitter(0.80, 0.05), template: main,
                          plusTeeth: true, minusTeeth: true))
        lobes.append(Lobe(angle: r.range(-3, 3), length: 1, template: main, plusTeeth: true, minusTeeth: true))
        lobes.append(Lobe(angle: -side + r.range(-3, 3), length: r.jitter(0.80, 0.05), template: main,
                          plusTeeth: true, minusTeeth: true))
        lobes.append(Lobe(angle: -low, length: r.jitter(0.32, 0.1), template: main, plusTeeth: false, minusTeeth: false))
        let sinus = [r.jitter(0.80, 0.04), r.jitter(0.84, 0.04), r.jitter(0.84, 0.04), r.jitter(0.80, 0.04)]
        let d = palmate(lobes, sinus: sinus, base: 0.4, toothJitter: 0.25, sideVeins: [0.4, 0.62], sideAngle: 50, &r)
        let pet = (length: r.range(0.16, 0.21), angle: r.range(-14, 14))
        return finish(d, margin: Margin(teeth: .double, amplitude: 0.017, wavelength: 0.044, wobble: 0.004),
                      petiole: pet, heart: Vec(0, 0.15), aspect: 1, &r)
    }

    fileprivate static func japaneseMaple(_ r: inout Rand) -> Geometry {
        let t = LobeTemplate(
            toothed: [Key(0.055, 0.84), Key(0.10, 0.68), Key(0.112, 0.54), Key(0.085, 0.40, .smooth, 0.5)],
            plain: [Key(0.055, 0.84), Key(0.10, 0.68), Key(0.112, 0.54), Key(0.085, 0.40, .smooth, 0.5)])
        let a1 = r.range(36, 40), a2 = r.range(74, 80), a3 = r.range(114, 122)
        let angles: [CGFloat] = [a3, a2, a1, 0, -a1, -a2, -a3]
        let lengths: [CGFloat] = [0.5, 0.78, 0.93, 1, 0.93, 0.78, 0.5]
        var lobes: [Lobe] = []
        for i in 0..<7 {
            lobes.append(Lobe(angle: angles[i] + r.range(-3, 3), length: r.jitter(lengths[i], 0.05), template: t,
                              plusTeeth: true, minusTeeth: true))
        }
        var sinus: [CGFloat] = []
        for _ in 0..<6 { sinus.append(r.range(0.62, 0.7)) }
        let d = palmate(lobes, sinus: sinus, base: 0.35, toothJitter: 0, sideVeins: [0.34, 0.52, 0.7], sideAngle: 55, &r)
        let pet = (length: r.range(0.2, 0.26), angle: r.range(-14, 14))
        var g = finish(d, margin: Margin(teeth: .double, amplitude: 0.014, wavelength: 0.032, wobble: 0.003),
                       petiole: pet, heart: Vec(0, 0.1), aspect: 1, &r)
        g.petioleW0 = 0.03
        g.petioleW1 = 0.02
        return g
    }

    fileprivate static func sweetgum(_ r: inout Rand) -> Geometry {
        let t = LobeTemplate(
            toothed: [Key(0.048, 0.865), Key(0.102, 0.725), Key(0.165, 0.58), Key(0.205, 0.47, .smooth, 0.5)],
            plain: [Key(0.048, 0.865), Key(0.102, 0.725), Key(0.165, 0.58), Key(0.205, 0.47, .smooth, 0.5)])
        let a1 = r.range(62, 72), a2 = r.range(122, 134)
        let angles: [CGFloat] = [a2, a1, 0, -a1, -a2]
        let lengths: [CGFloat] = [0.62, 0.88, 1, 0.88, 0.62]
        var lobes: [Lobe] = []
        for i in 0..<5 {
            lobes.append(Lobe(angle: angles[i] + r.range(-5, 5), length: r.jitter(lengths[i], 0.07), template: t,
                              plusTeeth: true, minusTeeth: true))
        }
        var sinus: [CGFloat] = []
        for _ in 0..<4 { sinus.append(r.range(0.76, 0.82)) }
        let d = palmate(lobes, sinus: sinus, base: 0.3, toothJitter: 0, sideVeins: [0.38, 0.6], sideAngle: 52, &r)
        let pet = (length: r.range(0.17, 0.22), angle: r.range(-14, 14))
        return finish(d, margin: Margin(teeth: .serrate, amplitude: 0.011, wavelength: 0.03, wobble: 0.003),
                      petiole: pet, heart: Vec(0, 0.1), aspect: 1, &r)
    }

    // MARK: Pinnate leaves (oak, birch, aspen, beech, elm)

    fileprivate static func oak(white: Bool, _ r: inout Rand) -> Geometry {
        // Lobes leave the midrib at `t`, reach `len` outward at `angle` degrees from the midrib, `half` wide,
        // with parallel sides running down into rounded sinuses.
        // English oak: obovate, five pairs of rounded lobes, small auricles at the base.
        // White oak: fewer, finger-like lobes cut by deep sinuses.
        let ts: [CGFloat] = white ? [0.05, 0.22, 0.41, 0.59] : [0.05, 0.18, 0.33, 0.48, 0.63]
        let lens: [CGFloat] = white ? [0.23, 0.38, 0.42, 0.32] : [0.15, 0.25, 0.32, 0.34, 0.27]
        let angles: [CGFloat] = white ? [70, 62, 54, 46] : [66, 61, 57, 53, 47]
        let halves: [CGFloat] = white ? [0.048, 0.058, 0.062, 0.055] : [0.045, 0.056, 0.066, 0.068, 0.06]
        let depth: CGFloat = white ? 0.3 : 0.5
        var veins: [Vein] = [midrib(0.965)]

        func side(_ s: CGFloat, _ shift: CGFloat, _ r: inout Rand) -> (keys: [Key], top: CGFloat) {
            var keys: [Key] = []
            var prevUpper: CGFloat
            var prevSinusX: CGFloat
            if white {
                keys.append(Key(0.045 * s, 0.025))
                prevUpper = 0.0
                prevSinusX = 0.045
            } else {
                keys.append(Key(0.035 * s, -0.012))
                keys.append(Key(0.062 * s, 0.022))
                prevUpper = 0.03
                prevSinusX = 0.04
            }
            var prevTipY: CGFloat = 0
            for i in 0..<ts.count {
                var t = ts[i] + shift + r.range(-0.015, 0.015)
                let len = lens[i] * r.range(0.86, 1.12)
                let a = (angles[i] + r.range(-5, 5)) * .pi / 180
                let w = halves[i] * r.range(0.88, 1.12)
                let d = Vec(sin(a) * s, cos(a))
                let nUp = Vec(-cos(a) * s, sin(a))
                let sinusX = depth * len * sin(a)
                let r0 = sinusX / sin(a) + w * 0.6
                // Keep each lobe clear of the one below so the outline never folds over itself.
                let lowBaseY = t + d.y * r0 - nUp.y * w
                if lowBaseY < prevUpper + 0.035 { t += prevUpper + 0.035 - lowBaseY }
                let m = Vec(0, t)
                let back = min(len * 0.3, w * 1.1)
                let lowerBase = m + d * r0 - nUp * w
                let lower = m + d * (len - back) - nUp * w
                let tip = m + d * len
                let upper = m + d * (len - back * 1.05) + nUp * (w * 0.95)
                let upperBase = m + d * r0 + nUp * (w * 0.95)
                if i > 0 || white {
                    let sx = min(prevSinusX, sinusX) * 0.92
                    keys.append(Key(sx * s, (prevUpper + lowerBase.y) * 0.5))
                }
                for p in [lowerBase, lower, tip, upper, upperBase] { keys.append(Key(p, .smooth, 0)) }
                veins.append(Vein(pts: curve(m + Vec(0, 0.012), m + d * (len * 0.86), bend: 0.04 * s),
                                  w0: 0.012, w1: 0.003, major: false))
                prevUpper = upperBase.y
                prevSinusX = sinusX
                prevTipY = tip.y
            }
            let sinusY = prevUpper + 0.035
            keys.append(Key(min(prevSinusX, 0.1) * 0.92 * s, sinusY))
            keys.append(Key(0.115 * s, sinusY + 0.075))
            return (keys, max(prevTipY + 0.12, sinusY + 0.15))
        }

        let right = side(1, 0, &r)
        let left = side(-1, white ? 0.04 : 0.045, &r)
        var d = Draft()
        let top = max(right.top, left.top)
        veins[0] = midrib(top - 0.035)
        d.keys = [Key(0, 0, .corner, 0)] + right.keys + [Key(0, top, .smooth, 0)] + left.keys.reversed()
        d.veins = veins
        let pet = (length: r.range(0.05, 0.08), angle: r.range(-18, 18))
        var g = finish(d, margin: Margin(teeth: .none, wobble: 0.0045), petiole: pet,
                       heart: Vec(0, 0.5), aspect: white ? 0.8 : 0.65, &r)
        g.petioleW0 = 0.032
        return g
    }

    fileprivate static func birch(_ r: inout Rand) -> Geometry {
        // Silver birch: triangular-ovate, broad wedge base, drawn-out acuminate tip.
        let right = [Key(0.17, 0.03, .smooth, 0.3), Key(0.33, 0.115), Key(0.405, 0.235), Key(0.38, 0.39),
                     Key(0.29, 0.56), Key(0.175, 0.74), Key(0.075, 0.885, .smooth, 0.6), Key(0.032, 0.948, .smooth, 0.35)]
        var d = Draft()
        d.keys = bilateral(base: Key(0, 0, .corner, 0), right: right, tip: Key(0, 1, .tip, 0), jitter: 0.05, &r)
        d.veins = [midrib(0.965)]
        d.rays = pinnateRays([0.05, 0.14, 0.23, 0.32, 0.41, 0.50, 0.59, 0.68], angle: 46, reach: 0.9, curl: 0.05,
                             w0: 0.011, w1: 0.003, leftOffset: 0.015, &r)
        let pet = (length: r.range(0.15, 0.2), angle: r.range(-15, 15))
        return finish(d, margin: Margin(teeth: .double, amplitude: 0.022, wavelength: 0.058, wobble: 0.003),
                      petiole: pet, heart: Vec(0, 0.36), aspect: 0.62, &r)
    }

    fileprivate static func aspen(_ r: inout Rand) -> Geometry {
        let right = [Key(0.15, -0.025, .smooth, 0.2), Key(0.35, 0.03), Key(0.47, 0.21), Key(0.47, 0.43),
                     Key(0.38, 0.64), Key(0.22, 0.81), Key(0.085, 0.915, .smooth, 0.5)]
        var d = Draft()
        d.keys = bilateral(base: Key(0, 0, .corner, 0), right: right, tip: Key(0, 1, .tip, 0), jitter: 0.05, &r)
        d.veins = [midrib(0.955)]
        d.rays = pinnateRays([0.02], angle: 64, reach: 0.86, curl: 0.12, w0: 0.016, w1: 0.003, leftOffset: 0, &r)
        d.rays += pinnateRays([0.2, 0.34, 0.48, 0.62], angle: 48, reach: 0.85, curl: 0.1,
                              w0: 0.011, w1: 0.003, leftOffset: 0.02, &r)
        let pet = (length: r.range(0.2, 0.26), angle: r.range(-15, 15))
        return finish(d, margin: Margin(teeth: .crenate, amplitude: 0.019, wavelength: 0.07, wobble: 0.003),
                      petiole: pet, heart: Vec(0, 0.38), aspect: 0.85, &r)
    }

    fileprivate static func beech(_ r: inout Rand) -> Geometry {
        let right = [Key(0.10, 0.02, .smooth, 0.2), Key(0.23, 0.11), Key(0.31, 0.28), Key(0.32, 0.48),
                     Key(0.26, 0.67), Key(0.16, 0.83), Key(0.065, 0.935, .smooth, 0.5)]
        var d = Draft()
        d.keys = bilateral(base: Key(0, 0, .corner, 0), right: right, tip: Key(0, 1, .tip, 0), jitter: 0.05, &r)
        d.veins = [midrib(0.965)]
        d.rays = pinnateRays([0.07, 0.16, 0.25, 0.34, 0.43, 0.52, 0.61, 0.70, 0.79], angle: 40, reach: 0.95,
                             curl: 0.03, w0: 0.012, w1: 0.004, leftOffset: 0.02, &r)
        let pet = (length: r.range(0.08, 0.12), angle: r.range(-15, 15))
        var g = finish(d, margin: Margin(teeth: .wavy, amplitude: 0.012, wavelength: 0.1, wobble: 0.003),
                       petiole: pet, heart: Vec(0, 0.4), aspect: 0.55, &r)
        g.veinBoost = 1.3
        return g
    }

    fileprivate static func elm(_ r: inout Rand) -> Geometry {
        let right = [Key(0.13, -0.005, .smooth, 0.3), Key(0.28, 0.10), Key(0.36, 0.28), Key(0.35, 0.50),
                     Key(0.28, 0.70), Key(0.16, 0.86), Key(0.06, 0.95, .smooth, 0.5)]
        let left = [Key(0.06, 0.09, .smooth, 0.3), Key(0.20, 0.17), Key(0.31, 0.32), Key(0.33, 0.52),
                    Key(0.27, 0.71), Key(0.155, 0.86), Key(0.06, 0.95, .smooth, 0.5)]
        var d = Draft()
        d.keys = bilateral(base: Key(0, 0, .corner, 0), right: right, tip: Key(0, 1, .tip, 0), left: left,
                           jitter: 0.04, &r)
        d.veins = [midrib(0.965)]
        var rays = pinnateRays([0.05, 0.12, 0.19, 0.26, 0.33, 0.40, 0.47, 0.54, 0.61, 0.68, 0.75, 0.82],
                               angle: 42, reach: 0.95, curl: 0.04, w0: 0.011, w1: 0.0035, leftOffset: 0.03, &r)
        rays.removeAll { $0.dir.x < 0 && $0.origin.y < 0.1 }
        d.rays = rays
        let pet = (length: r.range(0.07, 0.1), angle: r.range(-15, 15))
        var g = finish(d, margin: Margin(teeth: .double, amplitude: 0.02, wavelength: 0.048, wobble: 0.003),
                       petiole: pet, heart: Vec(0, 0.42), aspect: 0.62, &r)
        g.veinBoost = 1.3
        return g
    }

    // MARK: Ginkgo

    fileprivate static func ginkgo(notch: CGFloat, _ r: inout Rand) -> Geometry {
        func polar(_ deg: CGFloat, _ rad: CGFloat) -> Vec {
            let a = deg * .pi / 180
            return Vec(rad * sin(a), rad * cos(a))
        }
        let spread = r.range(54, 61)
        func half(_ r: inout Rand) -> [Key] {
            let s = spread + r.range(-3, 3)
            return [Key(polar(s - 11, 0.32), .smooth, 0), Key(polar(s - 4, 0.64), .smooth, 0),
                    Key(polar(s, 0.86), .smooth, 0.2), Key(polar(s - 7, 0.99 * r.jitter(1, 0.02)), .smooth, 1),
                    Key(polar(s * 0.62, 1.03 * r.jitter(1, 0.02)), .smooth, 1),
                    Key(polar(s * 0.36, 1.03 * r.jitter(1, 0.02)), .smooth, 1),
                    Key(polar(s * 0.14, 1.0 * r.jitter(1, 0.02)), .smooth, 1),
                    Key(polar(2.5, 1 - notch * 0.35), .smooth, 0.4)]
        }
        let right = half(&r)
        let left = half(&r)
        var d = Draft()
        d.keys = [Key(0, 0, .corner, 0)] + right + [Key(polar(0, 1 - notch), .corner, 0)]
            + left.reversed().map { $0.mirrored }
        d.veins = []
        let n = 34
        for i in 0..<n {
            let phi = (-spread * 0.96 + 2 * spread * 0.96 * CGFloat(i) / CGFloat(n - 1)) * .pi / 180
            let o = Vec(0, 0) + Vec(sin(phi), cos(phi)) * r.range(0.04, 0.22)
            d.rays.append(Ray(origin: o, dir: Vec(sin(phi), cos(phi)), reach: 0.96, w0: 0.0065, w1: 0.0045,
                              curl: 0, major: false))
        }
        let pet = (length: r.range(0.26, 0.32), angle: r.range(-12, 12))
        var g = finish(d, margin: Margin(teeth: .wavy, amplitude: 0.01, wavelength: 0.1, wobble: 0.007),
                       petiole: pet, heart: Vec(0, 0.12), aspect: 1, &r)
        g.petioleW0 = 0.03
        g.petioleW1 = 0.022
        g.veinBoost = 0.75
        return g
    }

    fileprivate static func geometry(_ form: Form, _ r: inout Rand) -> Geometry {
        switch form {
        case .sugarMaple: return sugarMaple(&r)
        case .redMaple: return redMaple(&r)
        case .japaneseMaple: return japaneseMaple(&r)
        case .sweetgum: return sweetgum(&r)
        case .englishOak: return oak(white: false, &r)
        case .whiteOak: return oak(white: true, &r)
        case .birch: return birch(&r)
        case .aspen: return aspen(&r)
        case .beech: return beech(&r)
        case .elm: return elm(&r)
        case .ginkgo: return ginkgo(notch: 0.14, &r)
        case .ginkgoBilobed: return ginkgo(notch: 0.36, &r)
        }
    }

    // MARK: Painting

    /// A filled polygon around a polyline whose width tapers from w0 to w1.
    fileprivate static func tapered(_ p: [CGPoint], w0: CGFloat, w1: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let n = p.count
        guard n >= 2 else { return path }
        var lens = [CGFloat](repeating: 0, count: n)
        for i in 1..<n { lens[i] = lens[i - 1] + hypot(p[i].x - p[i - 1].x, p[i].y - p[i - 1].y) }
        let total = max(lens[n - 1], 1e-6)
        var left: [CGPoint] = []
        var right: [CGPoint] = []
        left.reserveCapacity(n)
        right.reserveCapacity(n)
        for i in 0..<n {
            let a = p[max(0, i - 1)], b = p[min(n - 1, i + 1)]
            var tx = b.x - a.x, ty = b.y - a.y
            let l = max(hypot(tx, ty), 1e-6)
            tx /= l
            ty /= l
            let hw = (w0 + (w1 - w0) * lens[i] / total) * 0.5
            left.append(CGPoint(x: p[i].x - ty * hw, y: p[i].y + tx * hw))
            right.append(CGPoint(x: p[i].x + ty * hw, y: p[i].y - tx * hw))
        }
        path.addLines(between: left + right.reversed())
        path.closeSubpath()
        return path
    }

    fileprivate static func softDot(_ ctx: CGContext, _ c: CGPoint, _ radius: CGFloat, _ color: RGB, _ alpha: CGFloat) {
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                 colors: [color.cg(alpha), color.cg(alpha * 0.45), color.cg(0)] as CFArray,
                                 locations: [0, 0.5, 1]) else { return }
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: [])
    }

    /// Draws `body` far off to the side with a shadow cast back into place: a cheap Gaussian blur.
    fileprivate static func blurred(_ ctx: CGContext, color: CGColor, blur: CGFloat, _ body: (CGContext) -> Void) {
        let shift: CGFloat = 8192
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: -shift, height: 0), blur: blur, color: color)
        ctx.translateBy(x: shift, y: 0)
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.setStrokeColor(gray: 0, alpha: 1)
        body(ctx)
        ctx.restoreGState()
    }

    /// Soft darkening that creeps in from the blade margin (call while clipped to the blade):
    /// the shadow of everything outside the blade, cast inward.
    fileprivate static func innerShadow(_ ctx: CGContext, _ blade: CGPath, _ cell: CGRect, color: CGColor,
                                        fill: CGColor, blur: CGFloat) {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: blur, color: color)
        ctx.addRect(cell.insetBy(dx: -cell.width, dy: -cell.height))
        ctx.addPath(blade)
        ctx.setFillColor(fill)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }

    /// Soft-light grain: a coarse mottle plus fine pixel noise, so blades read as tissue rather than vector fills.
    fileprivate static func makeGrain(size: Int) -> CGImage? {
        guard size > 0, let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                                            space: CGColorSpaceCreateDeviceGray(),
                                            bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let raw = ctx.data else { return nil }
        let bytes = raw.bindMemory(to: UInt8.self, capacity: size * size)
        let bpr = ctx.bytesPerRow
        var rng = Rand(seed: 0x6EA1_9A17)
        let grid = 14
        var coarse = [CGFloat](repeating: 0, count: (grid + 1) * (grid + 1))
        for i in coarse.indices { coarse[i] = rng.unit() }
        let scale = CGFloat(grid) / CGFloat(size)
        for y in 0..<size {
            let fy = CGFloat(y) * scale
            let iy = min(grid - 1, Int(fy))
            var ty = fy - CGFloat(iy)
            ty = ty * ty * (3 - 2 * ty)
            for x in 0..<size {
                let fx = CGFloat(x) * scale
                let ix = min(grid - 1, Int(fx))
                var tx = fx - CGFloat(ix)
                tx = tx * tx * (3 - 2 * tx)
                let c00 = coarse[iy * (grid + 1) + ix], c10 = coarse[iy * (grid + 1) + ix + 1]
                let c01 = coarse[(iy + 1) * (grid + 1) + ix], c11 = coarse[(iy + 1) * (grid + 1) + ix + 1]
                let c = (c00 + (c10 - c00) * tx) + ((c01 + (c11 - c01) * tx) - (c00 + (c10 - c00) * tx)) * ty
                let v = 0.5 + (c - 0.5) * 0.5 + (rng.unit() - 0.5) * 0.32
                bytes[y * bpr + x] = UInt8(max(0, min(255, Int(v * 255))))
            }
        }
        return ctx.makeImage()
    }

    fileprivate static func pointInside(_ path: CGPath, _ bb: CGRect, _ rng: inout Rand, inset: CGFloat = 0) -> CGPoint {
        var p = CGPoint(x: bb.midX, y: bb.midY)
        for _ in 0..<40 {
            p = CGPoint(x: rng.range(bb.minX, bb.maxX), y: rng.range(bb.minY, bb.maxY))
            if path.contains(p) {
                if inset <= 0 { return p }
                let probes = [CGPoint(x: p.x + inset, y: p.y), CGPoint(x: p.x - inset, y: p.y),
                              CGPoint(x: p.x, y: p.y + inset), CGPoint(x: p.x, y: p.y - inset)]
                if probes.allSatisfy({ path.contains($0) }) { return p }
            }
        }
        return p
    }

    fileprivate static func paint(_ v: Variant, in cell: CGRect, ctx: CGContext, grain: CGImage?) -> CGFloat {
        var rng = Rand(seed: v.seed)
        var g = geometry(v.form, &rng)
        g.warp(bend: rng.range(-0.06, 0.06), asym: rng.range(-0.05, 0.05))
        let pal = v.palette
        let side = cell.width
        let unit = side / 80            // 1.0 at the reference size (40 pt @2x)
        let pad = max(3, (side * 0.05).rounded(.up))
        let fit = min(side * 0.88, side - 2 * pad - 2)

        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for p in g.outline {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let pw = g.petioleW0 * 0.6
        for p in g.petiole {
            minX = min(minX, p.x - pw); maxX = max(maxX, p.x + pw)
            minY = min(minY, p.y - pw); maxY = max(maxY, p.y + pw)
        }
        let k = fit / max(maxX - minX, maxY - minY)
        let ox = cell.midX - (minX + maxX) * 0.5 * k
        let oy = cell.midY - (minY + maxY) * 0.5 * k
        func T(_ p: Vec) -> CGPoint { CGPoint(x: ox + p.x * k, y: oy + p.y * k) }

        ctx.saveGState()
        ctx.clip(to: cell)

        // Petiole, under the blade.
        let stem = g.petiole.map(T)
        drawPetiole(ctx, stem, w0: max(g.petioleW0 * k, 1.1 * unit), w1: max(g.petioleW1 * k, 0.8 * unit), pal: pal)

        let blade = CGMutablePath()
        blade.addLines(between: g.outline.map(T))
        blade.closeSubpath()
        let bb = blade.boundingBoxOfPath

        ctx.saveGState()
        ctx.addPath(blade)
        ctx.clip()

        // 1. Base colour: elliptical gradient from the heart of the leaf out to the tips.
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)
        let hc = T(g.heart)
        var radius: CGFloat = 1
        for p in g.outline {
            let q = T(p)
            let dx = (q.x - hc.x) / g.gradAspect, dy = q.y - hc.y
            radius = max(radius, (dx * dx + dy * dy).squareRoot())
        }
        if let base = CGGradient(colorsSpace: srgb, colors: [pal.center.cg(), pal.mid.cg(), pal.outer.cg()] as CFArray,
                                 locations: [0, 0.5, 1]) {
            ctx.saveGState()
            ctx.translateBy(x: hc.x, y: hc.y)
            ctx.scaleBy(x: g.gradAspect, y: 1)
            ctx.drawRadialGradient(base, startCenter: .zero, startRadius: 0, endCenter: .zero,
                                   endRadius: radius * 0.92, options: [.drawsAfterEndLocation])
            ctx.restoreGState()
        }

        // 2. Mottling: soft patches a little lighter or darker than the blade.
        let blobs = 10 + Int(rng.unit() * 8)
        for _ in 0..<blobs {
            let p = CGPoint(x: rng.range(bb.minX, bb.maxX), y: rng.range(bb.minY, bb.maxY))
            let rad = fit * rng.range(0.08, 0.2)
            let light = rng.chance(0.5)
            let col = light ? pal.center.lighter(0.12) : pal.outer.darker(0.14)
            softDot(ctx, p, rad, col, rng.range(0.10, 0.24))
        }

        // 3. A leaf still turning keeps some green along its main veins.
        if let green = pal.chlorophyll {
            let band = CGMutablePath()
            for vein in g.veins where vein.major {
                band.addLines(between: Array(vein.pts.prefix(Int(Double(vein.pts.count) * 0.8))).map(T))
            }
            blurred(ctx, color: green.cg(0.55), blur: fit * 0.07) { c in
                c.addPath(band)
                c.setLineWidth(fit * 0.06)
                c.setLineCap(.round)
                c.strokePath()
            }
        }

        // 4. Blemishes.
        for mark in v.marks {
            switch mark {
            case .speckles:
                let clusters = 1 + Int(rng.unit() * 2)
                for _ in 0..<clusters {
                    let c = pointInside(blade, bb, &rng, inset: fit * 0.08)
                    let count = 2 + Int(rng.unit() * 4)
                    for _ in 0..<count {
                        let p = CGPoint(x: c.x + rng.range(-1, 1) * fit * 0.1, y: c.y + rng.range(-1, 1) * fit * 0.1)
                        let rad = rng.range(0.3, 0.8) * unit
                        softDot(ctx, p, rad * 2.8, pal.center.lighter(0.15), 0.16)
                        ctx.setFillColor(RGB(0x4A2A12).mix(pal.edge, 0.4).cg(rng.range(0.3, 0.5)))
                        ctx.fillEllipse(in: CGRect(x: p.x - rad, y: p.y - rad * 0.8, width: rad * 2, height: rad * 1.6))
                    }
                }
            case .tarSpots:
                let count = 1 + Int(rng.unit() * 2)
                for _ in 0..<count {
                    let p = pointInside(blade, bb, &rng, inset: fit * 0.12)
                    let rad = fit * rng.range(0.014, 0.024)
                    softDot(ctx, p, rad * 3, RGB(0xF2CF55), 0.4)
                    blurred(ctx, color: RGB(0x3A2610).cg(0.62), blur: 0.8 * unit) { c in
                        for _ in 0..<3 {
                            let q = CGPoint(x: p.x + rng.range(-0.5, 0.5) * rad, y: p.y + rng.range(-0.5, 0.5) * rad)
                            let rr = rad * rng.range(0.55, 0.85)
                            c.fillEllipse(in: CGRect(x: q.x - rr, y: q.y - rr, width: rr * 2, height: rr * 2))
                        }
                    }
                }
            case .blotch:
                let q = g.outline[Int(rng.unit() * CGFloat(g.outline.count - 1))]
                let c = T(q + (g.heart - q) * rng.range(0.12, 0.25))
                let rad = fit * rng.range(0.1, 0.17)
                let col = RGB(0x6B4322).mix(pal.edge, 0.35)
                blurred(ctx, color: col.cg(0.42), blur: rad * 0.5) { cc in
                    for _ in 0..<4 {
                        let o = CGPoint(x: c.x + rng.range(-0.6, 0.6) * rad, y: c.y + rng.range(-0.6, 0.6) * rad)
                        let rr = rad * rng.range(0.45, 0.8)
                        cc.fillEllipse(in: CGRect(x: o.x - rr, y: o.y - rr, width: rr * 2, height: rr * 2))
                    }
                }
            }
        }

        // 5. A gentle fold: one half of the blade catches more light than the other.
        let foldK = rng.range(0.6, 1.5)
        if let fold = CGGradient(colorsSpace: srgb,
                                 colors: [CGColor(srgbRed: 1, green: 0.97, blue: 0.88, alpha: 0.11 * foldK),
                                          CGColor(srgbRed: 1, green: 0.97, blue: 0.88, alpha: 0.03 * foldK),
                                          CGColor(srgbRed: 0.1, green: 0.03, blue: 0, alpha: 0.03 * foldK),
                                          CGColor(srgbRed: 0.1, green: 0.03, blue: 0, alpha: 0.12 * foldK)] as CFArray,
                                 locations: [0, 0.46, 0.54, 1]) {
            let lit = rng.chance(0.5)
            let a = CGPoint(x: lit ? bb.minX : bb.maxX, y: bb.midY)
            let b = CGPoint(x: lit ? bb.maxX : bb.minX, y: bb.midY)
            ctx.drawLinearGradient(fold, start: a, end: b, options: [])
        }

        // 6. Tissue grain.
        if let grain {
            ctx.saveGState()
            ctx.setBlendMode(.softLight)
            ctx.setAlpha(0.55)
            let gx = cell.minX - rng.range(0, side), gy = cell.minY - rng.range(0, side)
            ctx.draw(grain, in: CGRect(x: gx, y: gy, width: side * 2, height: side * 2))
            ctx.restoreGState()
        }

        // 7. Margins darken and brown first.
        let rimFill = pal.edge.cg()
        innerShadow(ctx, blade, cell, color: pal.edge.cg(0.45 + pal.dry * 0.28), fill: rimFill, blur: fit * 0.085)
        innerShadow(ctx, blade, cell, color: pal.edge.cg(0.26 + pal.dry * 0.2), fill: rimFill, blur: max(1, 1.5 * unit))

        // 8. Veins: a faint groove shadow, then the paler vein itself.
        let minW = 0.4 * unit
        let groove = CGSize(width: 0.45 * unit, height: -0.45 * unit)
        for major in [false, true] {
            let alpha = pal.veinAlpha * g.veinBoost * (major ? 1 : 0.72)
            ctx.saveGState()
            ctx.setAlpha(min(0.3, 0.16 * g.veinBoost))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.setFillColor(pal.edge.cg())
            ctx.translateBy(x: groove.width, y: groove.height)
            for vein in g.veins where vein.major == major {
                ctx.addPath(tapered(vein.pts.map(T), w0: max(vein.w0 * k, minW), w1: max(vein.w1 * k, minW * 0.6)))
                ctx.fillPath()
            }
            ctx.endTransparencyLayer()
            ctx.restoreGState()

            ctx.saveGState()
            ctx.setAlpha(min(0.85, alpha))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.setFillColor(pal.vein.cg())
            for vein in g.veins where vein.major == major {
                ctx.addPath(tapered(vein.pts.map(T), w0: max(vein.w0 * k, minW), w1: max(vein.w1 * k, minW * 0.6)))
                ctx.fillPath()
            }
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }

        // 9. Thin darker rim, kept inside the blade so the silhouette stays crisp.
        //    (A tight inner shadow: far cheaper than stroking the dense toothed outline.)
        innerShadow(ctx, blade, cell, color: pal.edge.cg(0.62 + pal.dry * 0.2), fill: rimFill, blur: max(0.5, 0.75 * unit))

        ctx.restoreGState()   // blade clip
        ctx.restoreGState()   // cell clip

        let body = (bb.width + bb.height) * 0.5 / side
        return min(1, max(0.1, body))
    }

    fileprivate static func drawPetiole(_ ctx: CGContext, _ pts: [CGPoint], w0: CGFloat, w1: CGFloat, pal: Palette) {
        guard pts.count > 1 else { return }
        ctx.setFillColor(pal.petiole.cg())
        ctx.addPath(tapered(pts, w0: w0, w1: w1))
        ctx.fillPath()
        // The snapped end is a touch darker.
        let end = pts[pts.count - 1]
        let r = w1 * 0.6
        ctx.setFillColor(pal.petiole.darker(0.3).cg())
        ctx.fillEllipse(in: CGRect(x: end.x - r, y: end.y - r, width: r * 2, height: r * 2))
        // Highlight along one side.
        var shifted: [CGPoint] = []
        for i in 0..<pts.count {
            let a = pts[max(0, i - 1)], b = pts[min(pts.count - 1, i + 1)]
            let l = max(hypot(b.x - a.x, b.y - a.y), 1e-6)
            let off = w0 * 0.18
            shifted.append(CGPoint(x: pts[i].x - (b.y - a.y) / l * off, y: pts[i].y + (b.x - a.x) / l * off))
        }
        ctx.setFillColor(pal.petiole.lighter(0.35).cg(0.5))
        ctx.addPath(tapered(Array(shifted.dropLast(2)), w0: w0 * 0.32, w1: w1 * 0.25))
        ctx.fillPath()
    }
}
