import CoreGraphics
import Foundation

// MARK: - Public API

enum ToolKind { case rake, blower }

struct ToolSprite {
    let image: CGImage        // rendered at `scale` pixels per point, transparent background
    let pointSize: CGSize     // display size in points
    /// Where the tool acts, in points from the image's bottom-left: the centre of the rake's tine tips,
    /// or the blower's nozzle opening. The app puts this point exactly at the mouse position.
    let hotspot: CGPoint
}

enum ToolArt {
    static func sprite(_ kind: ToolKind, scale: CGFloat) -> ToolSprite {
        let scale = max(scale, 0.5)
        switch kind {
        case .rake:
            let (image, size) = render(rakeSize, scale: scale, shadow: true) { drawRake($0) }
            return ToolSprite(image: image, pointSize: size, hotspot: rakeHotspot)
        case .blower:
            let (image, size) = render(blowerSize, scale: scale, shadow: true) { drawBlower($0) }
            return ToolSprite(image: image, pointSize: size, hotspot: blowerHotspot)
        }
    }

    /// 18×18 pt menu icon at 2x, black silhouette on transparent, for use as an NSImage template.
    static func menuIcon(_ kind: ToolKind) -> CGImage {
        render(CGSize(width: 18, height: 18), scale: 2, shadow: false) { ctx in
            switch kind {
            case .rake: rakeIcon(ctx)
            case .blower: blowerIcon(ctx)
            }
        }.image
    }
}

// MARK: - Implementation

extension ToolArt {

    // MARK: Helpers

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
        func mix(_ o: RGB, _ t: CGFloat) -> RGB { RGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t) }
        func cg(_ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    }

    fileprivate static func gradient(_ stops: [(RGB, CGFloat)], alpha: CGFloat = 1) -> CGGradient? {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                   colors: stops.map { $0.0.cg(alpha) } as CFArray,
                   locations: stops.map { $0.1 })
    }

    fileprivate static func add(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    fileprivate static func sub(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    fileprivate static func mul(_ a: CGPoint, _ k: CGFloat) -> CGPoint { CGPoint(x: a.x * k, y: a.y * k) }
    fileprivate static func unit(_ a: CGPoint) -> CGPoint {
        let l = max(hypot(a.x, a.y), 1e-9)
        return CGPoint(x: a.x / l, y: a.y / l)
    }

    /// Renders in point coordinates; everything is composited as one layer so the drop shadow is unified.
    fileprivate static func render(_ size: CGSize, scale: CGFloat, shadow: Bool,
                                   _ draw: (CGContext) -> Void) -> (image: CGImage, size: CGSize) {
        let w = max(1, Int((size.width * scale).rounded(.up)))
        let h = max(1, Int((size.height * scale).rounded(.up)))
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
        if shadow {
            // Shadow parameters live in pixels (base space), so scale them by hand.
            ctx.setShadow(offset: CGSize(width: 1.6 * scale, height: -2.6 * scale), blur: 3.6 * scale,
                          color: CGColor(srgbRed: 0.06, green: 0.03, blue: 0.02, alpha: 0.34))
        }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        draw(ctx)
        ctx.restoreGState()
        ctx.endTransparencyLayer()
        return (ctx.makeImage()!, CGSize(width: CGFloat(w) / scale, height: CGFloat(h) / scale))
    }

    /// Fills `path` with a gradient running across a cylinder whose axis goes from `a` to `b`.
    fileprivate static func cylinder(_ ctx: CGContext, _ path: CGPath, axis a: CGPoint, _ b: CGPoint, radius: CGFloat,
                                     _ g: CGGradient?) {
        guard let g else { return }
        let d = unit(sub(b, a))
        let n = CGPoint(x: -d.y, y: d.x)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.drawLinearGradient(g, start: sub(a, mul(n, radius)), end: add(a, mul(n, radius)),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    fileprivate static func stroke(_ ctx: CGContext, _ path: CGPath, _ color: CGColor, _ width: CGFloat) {
        ctx.addPath(path)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }

    /// A pale rim along the top edges (reads on dark desktops): the outline nudged down, clipped inside.
    fileprivate static func topRim(_ ctx: CGContext, _ path: CGPath, alpha: CGFloat = 0.2, drop: CGFloat = 0.9) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.translateBy(x: 0.25, y: -drop)
        stroke(ctx, path, CGColor(srgbRed: 1, green: 0.97, blue: 0.9, alpha: alpha), 1.1)
        ctx.restoreGState()
    }

    fileprivate static func dot(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ color: CGColor) {
        ctx.setFillColor(color)
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }

    fileprivate static func glow(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ color: RGB, _ alpha: CGFloat) {
        guard let soft = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                    colors: [color.cg(alpha), color.cg(alpha * 0.4), color.cg(0)] as CFArray,
                                    locations: [0, 0.45, 1]) else { return }
        ctx.drawRadialGradient(soft, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
    }

    // MARK: Rake

    fileprivate static let rakeSize = CGSize(width: 98, height: 128)
    fileprivate static let rakeHotspot = CGPoint(x: 40, y: 9)
    fileprivate static let rakeNeck = CGPoint(x: 50, y: 60)

    fileprivate static func drawRake(_ ctx: CGContext) {
        let bamboo = RGB(0xD9B67B), bambooDark = RGB(0xA98450), bambooEdge = RGB(0x5E4322)
        let neck = rakeNeck
        let count = 13

        // Tines: flat bamboo strips, bowed a little outward, fanning from the neck to a level row of tips.
        var tines: [[CGPoint]] = []
        for i in 0..<count {
            let u = CGFloat(i) / CGFloat(count - 1) * 2 - 1
            let tip = CGPoint(x: rakeHotspot.x + 30 * u, y: rakeHotspot.y + 2.4 * u * u)
            let dir = unit(sub(tip, neck))
            let root = add(neck, mul(dir, 5))
            let perp = CGPoint(x: -dir.y, y: dir.x)
            let mid = mul(add(root, tip), 0.5)
            let ctrl = add(mid, mul(perp, 2.2 * u))
            var pts: [CGPoint] = []
            for j in 0...14 {
                let t = CGFloat(j) / 14, v = 1 - t
                pts.append(CGPoint(x: root.x * v * v + ctrl.x * 2 * v * t + tip.x * t * t,
                                   y: root.y * v * v + ctrl.y * 2 * v * t + tip.y * t * t))
            }
            tines.append(pts)
        }
        for pts in tines {
            let body = CGMutablePath()
            body.addLines(between: pts)
            stroke(ctx, body, bambooEdge.cg(0.9), 2.6)
            stroke(ctx, body, bamboo.cg(), 1.75)
            // The last few points curl toward the viewer: foreshortened, a touch broader and shaded.
            let curl = CGMutablePath()
            curl.addLines(between: Array(pts.suffix(3)))
            stroke(ctx, curl, bambooEdge.cg(0.9), 3.0)
            stroke(ctx, curl, bambooDark.cg(), 2.15)
            let hl = CGMutablePath()
            hl.addLines(between: Array(pts.dropLast(3)).map { CGPoint(x: $0.x - 0.35, y: $0.y + 0.15) })
            stroke(ctx, hl, RGB(0xFFF1D2).cg(0.55), 0.5)
            dot(ctx, pts[pts.count - 3], 0.55, RGB(0xFFF1D2).cg(0.5))
        }

        // Cross brace: a bamboo strip bound to every tine with a twist of wire.
        let rb: CGFloat = 27
        let first = tines[0], last = tines[count - 1]
        func angleAtRadius(_ pts: [CGPoint]) -> (CGFloat, CGPoint) {
            var best = pts[0], bestErr = CGFloat.greatestFiniteMagnitude
            for p in pts {
                let e = abs(hypot(p.x - neck.x, p.y - neck.y) - rb)
                if e < bestErr { bestErr = e; best = p }
            }
            return (atan2(best.y - neck.y, best.x - neck.x), best)
        }
        let a0 = angleAtRadius(first).0 - 0.06
        let a1 = angleAtRadius(last).0 + 0.06
        let brace = CGMutablePath()
        brace.addArc(center: neck, radius: rb, startAngle: a0, endAngle: a1, clockwise: false)
        stroke(ctx, brace, bambooEdge.cg(0.95), 3.4)
        stroke(ctx, brace, RGB(0xC29A5E).cg(), 2.5)
        let braceHL = CGMutablePath()
        braceHL.addArc(center: neck, radius: rb - 0.6, startAngle: a0 + 0.02, endAngle: a1 - 0.02, clockwise: false)
        stroke(ctx, braceHL, RGB(0xFFF1D2).cg(0.45), 0.5)
        for pts in tines {
            let (_, p) = angleAtRadius(pts)
            let radial = unit(sub(p, neck))
            let tie = CGMutablePath()
            tie.move(to: sub(p, mul(radial, 1.5)))
            tie.addLine(to: add(p, mul(radial, 1.5)))
            stroke(ctx, tie, RGB(0x2F2720).cg(0.85), 0.75)
        }

        // Handle: a turned wooden pole rising up and to the right, fading out (it's only a cursor).
        let angle: CGFloat = 58 * .pi / 180
        let hdir = CGPoint(x: cos(angle), y: sin(angle))
        let hn = CGPoint(x: -hdir.y, y: hdir.x)
        let length: CGFloat = 76
        let r: CGFloat = 2.9
        let hStart = add(neck, mul(hdir, 8))
        let hEnd = add(neck, mul(hdir, length))
        let handle = CGMutablePath()
        handle.addLines(between: [add(hStart, mul(hn, r)), add(hEnd, mul(hn, r)), sub(hEnd, mul(hn, r)), sub(hStart, mul(hn, r))])
        handle.closeSubpath()
        cylinder(ctx, handle, axis: hStart, hEnd, radius: r,
                 gradient([(RGB(0x55321A), 0), (RGB(0x8A5730), 0.28), (RGB(0xC8935C), 0.66), (RGB(0xB47D48), 0.84),
                           (RGB(0x6A4222), 1)]))
        // Grain
        ctx.saveGState()
        ctx.addPath(handle)
        ctx.clip()
        ctx.translateBy(x: neck.x, y: neck.y)
        ctx.rotate(by: angle)
        let offsets: [CGFloat] = [-2.3, -1.6, -0.9, -0.2, 0.5, 1.2, 1.9, 2.5]
        for (i, y0) in offsets.enumerated() {
            let grain = CGMutablePath()
            let phase = CGFloat(i) * 1.7
            grain.move(to: CGPoint(x: 6, y: y0))
            var x: CGFloat = 6
            while x < length + 2 {
                x += 2
                grain.addLine(to: CGPoint(x: x, y: y0 + 0.22 * sin(x / 7 + phase) + 0.1 * sin(x / 2.3 + phase * 2)))
            }
            ctx.addPath(grain)
            ctx.setStrokeColor(RGB(0x3E2410).cg(i % 3 == 0 ? 0.32 : 0.18))
            ctx.setLineWidth(i % 3 == 0 ? 0.45 : 0.3)
            ctx.strokePath()
        }
        let shine = CGMutablePath()
        shine.move(to: CGPoint(x: 10, y: r * 0.42))
        shine.addLine(to: CGPoint(x: length, y: r * 0.42))
        ctx.addPath(shine)
        ctx.setStrokeColor(RGB(0xFFE9C8).cg(0.32))
        ctx.setLineWidth(0.7)
        ctx.strokePath()
        ctx.restoreGState()
        stroke(ctx, handle, RGB(0x3A2210).cg(0.55), 0.6)

        // Clamp plate holding the tine roots, with two rivets.
        let axis = unit(sub(rakeHotspot, neck))
        let p = CGPoint(x: -axis.y, y: axis.x)
        let corners = [add(sub(neck, mul(p, 4.6)), mul(axis, -1.6)), add(add(neck, mul(p, 4.6)), mul(axis, -1.6)),
                       add(add(neck, mul(p, 7.9)), mul(axis, 11.4)), add(sub(neck, mul(p, 7.9)), mul(axis, 11.4))]
        let plate = CGMutablePath()
        plate.move(to: mul(add(corners[0], corners[1]), 0.5))
        for i in 1...4 {
            plate.addArc(tangent1End: corners[i % 4], tangent2End: corners[(i + 1) % 4], radius: 1.3)
        }
        plate.closeSubpath()
        cylinder(ctx, plate, axis: neck, add(neck, mul(axis, 12)), radius: 8,
                 gradient([(RGB(0x4E5459), 0), (RGB(0x9AA1A7), 0.42), (RGB(0xC9CED2), 0.58), (RGB(0x6A7076), 1)]))
        stroke(ctx, plate, RGB(0x24282C).cg(0.6), 0.6)
        for s in [CGFloat(-1), 1] {
            let c = add(add(neck, mul(axis, 6.6)), mul(p, 3.7 * s))
            dot(ctx, c, 1.0, RGB(0x2C3034).cg())
            dot(ctx, CGPoint(x: c.x - 0.3, y: c.y + 0.3), 0.4, RGB(0xF2F4F6).cg(0.7))
        }

        // Metal ferrule where the pole meets the clamp.
        let f0 = add(neck, mul(hdir, -1.5)), f1 = add(neck, mul(hdir, 10))
        let fr: CGFloat = 3.45
        let ferrule = CGMutablePath()
        ferrule.addLines(between: [add(f0, mul(hn, fr)), add(f1, mul(hn, fr)), sub(f1, mul(hn, fr)), sub(f0, mul(hn, fr))])
        ferrule.closeSubpath()
        cylinder(ctx, ferrule, axis: f0, f1, radius: fr,
                 gradient([(RGB(0x474C51), 0), (RGB(0x7F868C), 0.3), (RGB(0xD5DADE), 0.64), (RGB(0x9CA3A9), 0.8),
                           (RGB(0x50565B), 1)]))
        for s in [CGFloat(1.2), 8.6] {
            let c = add(neck, mul(hdir, s))
            let ring = CGMutablePath()
            ring.move(to: add(c, mul(hn, fr)))
            ring.addLine(to: sub(c, mul(hn, fr)))
            stroke(ctx, ring, RGB(0x2A2E32).cg(0.6), 0.45)
        }
        stroke(ctx, ferrule, RGB(0x24282C).cg(0.6), 0.55)

        // Fade the far end of the pole away.
        ctx.saveGState()
        ctx.setBlendMode(.destinationOut)
        if let fade = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                 colors: [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1)] as CFArray,
                                 locations: [0, 1]) {
            ctx.drawLinearGradient(fade, start: add(neck, mul(hdir, length * 0.6)), end: add(neck, mul(hdir, length)),
                                   options: [.drawsAfterEndLocation])
        }
        ctx.restoreGState()
    }

    // MARK: Blower

    fileprivate static let blowerSize = CGSize(width: 148, height: 70)
    fileprivate static let blowerHotspot = CGPoint(x: 140, y: 25)

    fileprivate static func drawBlower(_ ctx: CGContext) {
        let y0 = blowerHotspot.y
        let gTop = RGB(0x76AE88), gMid = RGB(0x35714F), gLow = RGB(0x1B3F2D), gEdge = RGB(0x0D2016)
        let cTop = RGB(0x7A8087), cMid = RGB(0x41464C), cLow = RGB(0x1F2226), cEdge = RGB(0x0B0C0E)
        let charcoal = gradient([(cLow, 0), (cMid, 0.45), (cTop, 0.82), (cMid, 1)])

        // Loop handle (behind the body so its posts disappear into the housing).
        let loop = CGMutablePath()
        loop.move(to: CGPoint(x: 27.5, y: 37))
        loop.addCurve(to: CGPoint(x: 31.5, y: 58.5), control1: CGPoint(x: 27.5, y: 48), control2: CGPoint(x: 28.5, y: 56))
        loop.addCurve(to: CGPoint(x: 57, y: 59.5), control1: CGPoint(x: 38, y: 62), control2: CGPoint(x: 50, y: 62))
        loop.addCurve(to: CGPoint(x: 61, y: 37), control1: CGPoint(x: 61.5, y: 56.5), control2: CGPoint(x: 62, y: 46))
        let handle = loop.copy(strokingWithWidth: 5.8, lineCap: .round, lineJoin: .round, miterLimit: 4)
        if let charcoal {
            ctx.saveGState()
            ctx.addPath(handle)
            ctx.clip()
            ctx.drawLinearGradient(charcoal, start: CGPoint(x: 0, y: 52), end: CGPoint(x: 0, y: 63.5),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            // Soft rubber grip: fine ribs across the top bar.
            var x: CGFloat = 37
            while x < 52.5 {
                let rib = CGMutablePath()
                rib.move(to: CGPoint(x: x, y: 56.5))
                rib.addLine(to: CGPoint(x: x + 0.3, y: 64))
                ctx.addPath(rib)
                ctx.setStrokeColor(cEdge.cg(0.35))
                ctx.setLineWidth(0.45)
                ctx.strokePath()
                x += 1.7
            }
            ctx.restoreGState()
        }
        let loopHL = CGMutablePath()
        loopHL.addPath(loop, transform: CGAffineTransform(translationX: -0.5, y: 1.3))
        ctx.saveGState()
        ctx.addPath(handle)
        ctx.clip()
        stroke(ctx, loopHL, RGB(0xFFFFFF).cg(0.16), 1.1)
        ctx.restoreGState()
        stroke(ctx, handle, cEdge.cg(0.7), 0.7)

        // Trigger, inside the loop.
        // A slim lever curving back toward the palm.
        let trigger = CGMutablePath()
        trigger.move(to: CGPoint(x: 51.0, y: 57.6))
        trigger.addCurve(to: CGPoint(x: 49.2, y: 51.9), control1: CGPoint(x: 50.6, y: 55.4), control2: CGPoint(x: 49.4, y: 53.6))
        trigger.addCurve(to: CGPoint(x: 51.0, y: 51.7), control1: CGPoint(x: 49.1, y: 51.2), control2: CGPoint(x: 50.5, y: 51.0))
        trigger.addCurve(to: CGPoint(x: 53.6, y: 57.6), control1: CGPoint(x: 52.3, y: 53.4), control2: CGPoint(x: 53.4, y: 55.4))
        trigger.closeSubpath()
        cylinder(ctx, trigger, axis: CGPoint(x: 49, y: 54.5), CGPoint(x: 54, y: 54.5), radius: 2.6,
                 gradient([(RGB(0x5A5E64), 0), (RGB(0x34383C), 0.45), (RGB(0x16181B), 1)]))
        stroke(ctx, trigger, cEdge.cg(0.75), 0.5)

        // Tube, then its coupling ring, then the flattened nozzle.
        let tube = CGMutablePath()
        tube.addLines(between: [CGPoint(x: 70, y: y0 + 5.4), CGPoint(x: 125, y: y0 + 4.6),
                                CGPoint(x: 125, y: y0 - 4.6), CGPoint(x: 70, y: y0 - 5.4)])
        tube.closeSubpath()
        let green = gradient([(gLow, 0), (gMid, 0.32), (gTop, 0.72), (gMid, 0.9), (gLow.mix(gMid, 0.5), 1)])
        cylinder(ctx, tube, axis: CGPoint(x: 70, y: y0), CGPoint(x: 125, y: y0), radius: 5.4, green)
        let tubeShine = CGMutablePath()
        tubeShine.move(to: CGPoint(x: 80, y: y0 + 2.35))
        tubeShine.addLine(to: CGPoint(x: 121, y: y0 + 2.0))
        stroke(ctx, tubeShine, RGB(0xF4FFF6).cg(0.3), 0.8)
        // Two-piece tube joint.
        let joint = CGMutablePath()
        joint.move(to: CGPoint(x: 100, y: y0 + 5.0))
        joint.addLine(to: CGPoint(x: 100, y: y0 - 5.0))
        stroke(ctx, joint, gEdge.cg(0.55), 0.6)
        let jointHL = CGMutablePath()
        jointHL.move(to: CGPoint(x: 100.8, y: y0 + 4.9))
        jointHL.addLine(to: CGPoint(x: 100.8, y: y0 - 4.9))
        stroke(ctx, jointHL, RGB(0xF4FFF6).cg(0.18), 0.5)
        topRim(ctx, tube, alpha: 0.16, drop: 0.8)
        stroke(ctx, tube, gEdge.cg(0.65), 0.7)

        let nozzle = CGMutablePath()
        nozzle.move(to: CGPoint(x: 124, y: y0 + 5.2))
        nozzle.addLine(to: CGPoint(x: 127.5, y: y0 + 5.2))
        nozzle.addCurve(to: CGPoint(x: 140, y: y0 + 3.3), control1: CGPoint(x: 132, y: y0 + 4.9), control2: CGPoint(x: 137, y: y0 + 3.6))
        nozzle.addLine(to: CGPoint(x: 140, y: y0 - 3.3))
        nozzle.addCurve(to: CGPoint(x: 127.5, y: y0 - 5.2), control1: CGPoint(x: 137, y: y0 - 3.6), control2: CGPoint(x: 132, y: y0 - 4.9))
        nozzle.addLine(to: CGPoint(x: 124, y: y0 - 5.2))
        nozzle.closeSubpath()
        cylinder(ctx, nozzle, axis: CGPoint(x: 124, y: y0), CGPoint(x: 140, y: y0), radius: 5.2,
                 gradient([(cLow, 0), (cMid, 0.35), (cTop, 0.74), (cMid, 0.9), (cLow, 1)]))
        let collar = CGMutablePath()
        collar.move(to: CGPoint(x: 127.5, y: y0 + 5.1))
        collar.addLine(to: CGPoint(x: 127.5, y: y0 - 5.1))
        stroke(ctx, collar, cEdge.cg(0.6), 0.55)
        topRim(ctx, nozzle, alpha: 0.18, drop: 0.7)
        stroke(ctx, nozzle, cEdge.cg(0.7), 0.7)
        let mouth = CGRect(x: 140 - 1.15, y: y0 - 3.3, width: 2.3, height: 6.6)
        ctx.setFillColor(RGB(0x0A0B0C).cg())
        ctx.fillEllipse(in: mouth)
        ctx.addEllipse(in: mouth)
        ctx.setStrokeColor(RGB(0x9AA0A6).cg(0.55))
        ctx.setLineWidth(0.45)
        ctx.strokePath()

        // Coupling ring where the tube leaves the housing.
        let ring = CGPath(roundedRect: CGRect(x: 70.5, y: y0 - 6.4, width: 7.5, height: 12.8), cornerWidth: 1.4,
                          cornerHeight: 1.4, transform: nil)
        cylinder(ctx, ring, axis: CGPoint(x: 70, y: y0), CGPoint(x: 78, y: y0), radius: 6.4,
                 gradient([(cLow, 0), (cMid, 0.35), (cTop, 0.74), (cMid, 0.9), (cLow, 1)]))
        for x in [CGFloat(72.9), 75.6] {
            let rib = CGMutablePath()
            rib.move(to: CGPoint(x: x, y: y0 + 6.1))
            rib.addLine(to: CGPoint(x: x, y: y0 - 6.1))
            stroke(ctx, rib, cEdge.cg(0.45), 0.5)
        }
        stroke(ctx, ring, cEdge.cg(0.7), 0.6)

        // Motor housing: a smooth teardrop tapering into the tube.
        let body = CGMutablePath()
        body.move(to: CGPoint(x: 20, y: 11))
        body.addCurve(to: CGPoint(x: 60, y: 14), control1: CGPoint(x: 34, y: 9), control2: CGPoint(x: 50, y: 10.5))
        body.addCurve(to: CGPoint(x: 72, y: y0 - 5.6), control1: CGPoint(x: 66, y: 16), control2: CGPoint(x: 69, y: 18))
        body.addLine(to: CGPoint(x: 72, y: y0 + 5.6))
        body.addCurve(to: CGPoint(x: 60, y: 41), control1: CGPoint(x: 69, y: 34), control2: CGPoint(x: 66, y: 39))
        body.addCurve(to: CGPoint(x: 22, y: 43), control1: CGPoint(x: 48, y: 44), control2: CGPoint(x: 32, y: 44.5))
        body.addCurve(to: CGPoint(x: 9, y: 27), control1: CGPoint(x: 13, y: 41.5), control2: CGPoint(x: 9, y: 35))
        body.addCurve(to: CGPoint(x: 20, y: 11), control1: CGPoint(x: 9, y: 18), control2: CGPoint(x: 13, y: 12))
        body.closeSubpath()
        if let g = gradient([(gLow, 0), (gMid, 0.42), (gTop, 0.8), (gMid.mix(gTop, 0.4), 0.93), (gMid, 1)]) {
            ctx.saveGState()
            ctx.addPath(body)
            ctx.clip()
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 10), end: CGPoint(x: 0, y: 44.5), options: [])
            // Soft specular sheen along the top of the housing.
            ctx.saveGState()
            ctx.translateBy(x: 41, y: 37.5)
            ctx.scaleBy(x: 1, y: 0.2)
            glow(ctx, .zero, 21, RGB(0xF4FFF6), 0.34)
            ctx.restoreGState()
            // Mould seam and the shade it casts.
            let seam = CGMutablePath()
            seam.move(to: CGPoint(x: 43, y: 45))
            seam.addCurve(to: CGPoint(x: 46.5, y: 9), control1: CGPoint(x: 46.5, y: 34), control2: CGPoint(x: 47.5, y: 20))
            stroke(ctx, seam, gEdge.cg(0.5), 0.6)
            ctx.translateBy(x: 0.7, y: 0)
            stroke(ctx, seam, RGB(0xF4FFF6).cg(0.14), 0.5)
            ctx.restoreGState()
        }
        topRim(ctx, body, alpha: 0.2, drop: 1.0)
        stroke(ctx, body, gEdge.cg(0.7), 0.75)
        // Screws and a small amber power light.
        for c in [CGPoint(x: 29, y: 16.5), CGPoint(x: 58.5, y: 18.5)] {
            dot(ctx, c, 1.0, gEdge.cg(0.85))
            dot(ctx, CGPoint(x: c.x - 0.3, y: c.y + 0.3), 0.38, RGB(0xE9F2EC).cg(0.45))
        }
        glow(ctx, CGPoint(x: 36, y: 36.6), 2.6, RGB(0xFFB547), 0.45)
        dot(ctx, CGPoint(x: 36, y: 36.6), 0.85, RGB(0xF4A63A).cg())
        dot(ctx, CGPoint(x: 35.75, y: 36.85), 0.3, RGB(0xFFF1D0).cg(0.9))

        // Air intake on the back: a charcoal cap with grille slots.
        let capRect = CGRect(x: 13.6 - 6.2, y: 27 - 13.8, width: 12.4, height: 27.6)
        let cap = CGPath(ellipseIn: capRect, transform: nil)
        cylinder(ctx, cap, axis: CGPoint(x: 13.6, y: 13), CGPoint(x: 13.6, y: 41), radius: 6.2,
                 gradient([(cTop, 0), (cMid, 0.4), (cLow, 1)]))
        ctx.saveGState()
        ctx.addEllipse(in: capRect.insetBy(dx: 1.9, dy: 2.6))
        ctx.clip()
        var sy: CGFloat = 27 - 9.3
        while sy <= 27 + 9.4 {
            let slot = CGPath(roundedRect: CGRect(x: 6, y: sy - 0.65, width: 16, height: 1.3), cornerWidth: 0.6,
                              cornerHeight: 0.6, transform: nil)
            ctx.addPath(slot)
            ctx.setFillColor(RGB(0x0E0F11).cg())
            ctx.fillPath()
            let lip = CGMutablePath()
            lip.move(to: CGPoint(x: 6, y: sy - 0.95))
            lip.addLine(to: CGPoint(x: 22, y: sy - 0.95))
            stroke(ctx, lip, RGB(0x9AA0A6).cg(0.35), 0.4)
            sy += 3.1
        }
        ctx.restoreGState()
        topRim(ctx, cap, alpha: 0.18, drop: 0.8)
        stroke(ctx, cap, cEdge.cg(0.75), 0.7)
    }

    // MARK: Menu icons (template silhouettes, 18 pt)

    fileprivate static func rakeIcon(_ ctx: CGContext) {
        let black = CGColor(gray: 0, alpha: 1)
        let neck = CGPoint(x: 10.3, y: 8.6)
        ctx.setStrokeColor(black)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        // Handle
        ctx.setLineWidth(1.7)
        ctx.move(to: neck)
        ctx.addLine(to: CGPoint(x: 16.6, y: 16.9))
        ctx.strokePath()
        // Tines
        ctx.setLineWidth(1.0)
        let n = 7
        var crossings: [CGPoint] = []
        for i in 0..<n {
            let u = CGFloat(i) / CGFloat(n - 1) * 2 - 1
            let tip = CGPoint(x: 8.0 + 6.3 * u, y: 1.6 + 0.7 * u * u)
            let dir = unit(sub(tip, neck))
            ctx.move(to: add(neck, mul(dir, 1.0)))
            ctx.addLine(to: tip)
            crossings.append(add(neck, mul(dir, 4.4)))
        }
        ctx.strokePath()
        // Cross brace
        let a0 = atan2(crossings[0].y - neck.y, crossings[0].x - neck.x) - 0.08
        let a1 = atan2(crossings[n - 1].y - neck.y, crossings[n - 1].x - neck.x) + 0.08
        ctx.setLineWidth(1.1)
        ctx.addArc(center: neck, radius: 4.4, startAngle: a0, endAngle: a1, clockwise: false)
        ctx.strokePath()
        // Clamp at the neck
        ctx.setFillColor(black)
        let axis = unit(sub(CGPoint(x: 8, y: 1.6), neck))
        let p = CGPoint(x: -axis.y, y: axis.x)
        ctx.move(to: add(add(neck, mul(p, 1.3)), mul(axis, -0.6)))
        ctx.addLine(to: add(add(neck, mul(p, 2.4)), mul(axis, 2.8)))
        ctx.addLine(to: add(sub(neck, mul(p, 2.4)), mul(axis, 2.8)))
        ctx.addLine(to: add(sub(neck, mul(p, 1.3)), mul(axis, -0.6)))
        ctx.closePath()
        ctx.fillPath()
    }

    fileprivate static func blowerIcon(_ ctx: CGContext) {
        let black = CGColor(gray: 0, alpha: 1)
        ctx.setFillColor(black)
        ctx.setStrokeColor(black)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        // Flat loop handle set toward the back of the housing.
        ctx.setLineWidth(1.45)
        ctx.move(to: CGPoint(x: 2.2, y: 9.4))
        ctx.addCurve(to: CGPoint(x: 3.4, y: 12.4), control1: CGPoint(x: 2.3, y: 11.0), control2: CGPoint(x: 2.6, y: 12.0))
        ctx.addLine(to: CGPoint(x: 8.6, y: 12.6))
        ctx.addCurve(to: CGPoint(x: 9.4, y: 8.6), control1: CGPoint(x: 9.6, y: 12.2), control2: CGPoint(x: 9.7, y: 10.2))
        ctx.strokePath()
        // Housing: a teardrop that narrows into the tube.
        ctx.move(to: CGPoint(x: 2.6, y: 4.0))
        ctx.addCurve(to: CGPoint(x: 7.6, y: 4.6), control1: CGPoint(x: 4.4, y: 3.6), control2: CGPoint(x: 6.4, y: 3.8))
        ctx.addCurve(to: CGPoint(x: 9.8, y: 6.3), control1: CGPoint(x: 8.6, y: 5.1), control2: CGPoint(x: 9.3, y: 5.7))
        ctx.addLine(to: CGPoint(x: 9.8, y: 8.3))
        ctx.addCurve(to: CGPoint(x: 7.6, y: 9.9), control1: CGPoint(x: 9.3, y: 9.0), control2: CGPoint(x: 8.6, y: 9.6))
        ctx.addCurve(to: CGPoint(x: 2.4, y: 10.2), control1: CGPoint(x: 6.2, y: 10.4), control2: CGPoint(x: 3.8, y: 10.5))
        ctx.addCurve(to: CGPoint(x: 0.9, y: 7.1), control1: CGPoint(x: 1.4, y: 9.9), control2: CGPoint(x: 0.9, y: 8.6))
        ctx.addCurve(to: CGPoint(x: 2.6, y: 4.0), control1: CGPoint(x: 0.9, y: 5.6), control2: CGPoint(x: 1.5, y: 4.2))
        ctx.closePath()
        ctx.fillPath()
        // Long tube ending in a slightly flattened nozzle.
        ctx.move(to: CGPoint(x: 9.4, y: 8.2))
        ctx.addLine(to: CGPoint(x: 15.6, y: 8.05))
        ctx.addLine(to: CGPoint(x: 17.3, y: 7.85))
        ctx.addLine(to: CGPoint(x: 17.3, y: 6.55))
        ctx.addLine(to: CGPoint(x: 15.6, y: 6.35))
        ctx.addLine(to: CGPoint(x: 9.4, y: 6.2))
        ctx.closePath()
        ctx.fillPath()
        // Intake slots cut out of the back of the housing, and a gap marking the nozzle joint.
        ctx.setBlendMode(.clear)
        ctx.setLineWidth(0.7)
        for y in [CGFloat(5.7), 7.15, 8.6] {
            ctx.move(to: CGPoint(x: 2.0, y: y))
            ctx.addLine(to: CGPoint(x: 3.5, y: y))
        }
        ctx.strokePath()
        ctx.setLineCap(.butt)
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: 15.2, y: 5.8))
        ctx.addLine(to: CGPoint(x: 15.2, y: 8.6))
        ctx.strokePath()
        ctx.setBlendMode(.normal)
    }
}
