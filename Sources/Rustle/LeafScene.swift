import AppKit
import ImageIO
import SpriteKit

struct SceneSettings: Equatable {
    var fall: LeafFall = .steady
    var breeze: Breeze = .breezy
    var accumulate = true
    var windClears = true
    var onWindows = true
    var savePower = false
}

/// The leaf textures for one display scale, all cut from a single sheet so SpriteKit draws them in one batch.
struct LeafTextures {
    let textures: [SKTexture]
    let coverages: [CGFloat]

    init(scale: CGFloat) {
        let sheet = LeafArt.makeSheet(cellPointSize: 32, scale: scale)
        let base = SKTexture(cgImage: sheet.image)
        base.filteringMode = .linear
        textures = sheet.cells.map { SKTexture(rect: $0.rect, in: base) }
        coverages = sheet.cells.map { max(0.3, min(1, $0.coverage)) }
    }
}

// MARK: - Helpers

@inline(__always) private func rnd(_ a: CGFloat, _ b: CGFloat) -> CGFloat { CGFloat.random(in: a...b) }
@inline(__always) private func chance(_ p: CGFloat) -> Bool { CGFloat.random(in: 0..<1) < p }
@inline(__always) private func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), hi) }
@inline(__always) private func randomSign() -> CGFloat { Bool.random() ? 1 : -1 }

private func smoothstep(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat {
    let t = clamp((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)
}

private func closestPoint(onSegment a: CGPoint, _ b: CGPoint, to p: CGPoint) -> CGPoint {
    let abx = b.x - a.x, aby = b.y - a.y
    let len2 = abx * abx + aby * aby
    guard len2 > 0.0001 else { return a }
    let t = clamp(((p.x - a.x) * abx + (p.y - a.y) * aby) / len2, 0, 1)
    return CGPoint(x: a.x + abx * t, y: a.y + aby * t)
}

/// Smooth 1-D value noise in 0...1.
private struct ValueNoise {
    private var values: [CGFloat]

    init(seed: UInt64) {
        var state = seed | 1
        values = (0..<256).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(state >> 40) / CGFloat(1 << 24)
        }
    }

    func at(_ t: Double) -> CGFloat {
        let floor = t.rounded(.down)
        let i = Int(floor)
        let f = CGFloat(t - floor)
        let a = values[i & 255], b = values[(i &+ 1) & 255]
        return a + (b - a) * f * f * (3 - 2 * f)
    }
}

// MARK: - Model

private enum LeafState {
    case airborne, settling, resting, fading, removed
    /// Caught in the rake's tines and dragged along with it.
    case carried
}

private final class Leaf {
    let node: SKSpriteNode
    let size: CGFloat
    let coverage: CGFloat
    /// Half the length of the leaf blade, used for hits.
    let radius: CGFloat
    /// How far below its center a falling leaf touches down.
    let contactOffset: CGFloat

    var state = LeafState.airborne
    var isActive = false

    var x: CGFloat = 0, y: CGFloat = 0
    var vx: CGFloat = 0, vy: CGFloat = 0
    var angle: CGFloat = 0, spin: CGFloat = 0
    /// Tumble phase around the leaf's long axis, shown by squashing xScale.
    var flip: CGFloat = 0, flipRate: CGFloat = 0, baseFlipRate: CGFloat = 0
    var xScale: CGFloat = 1
    var tumbler = false
    var swayPhase: CGFloat = 0, swayFreq: CGFloat = 1.5, swayAmp: CGFloat = 30
    var tilt: CGFloat = 0.5
    var fallSpeed: CGFloat = 60
    var drag: CGFloat = 2.2
    var windCatch: CGFloat = 1
    var shade: CGFloat = 0
    /// Extra darkening for leaves low in a pile, in the shade of the ones above.
    var depthShade: CGFloat = 0, fromDepthShade: CGFloat = 0
    var alpha: CGFloat = 1
    /// A surface this leaf will not land on again (a full window ledge it rolled off).
    var ignoredSurface: Int?

    // Resting in a pile
    weak var surface: Surface?
    var column = -1
    var thickness: CGFloat = 4
    var restX: CGFloat = 0, restY: CGFloat = 0, restAngle: CGFloat = 0, restXScale: CGFloat = 1

    // Easing into its resting pose
    var settleT: CGFloat = 0, settleDuration: CGFloat = 0.3
    var fromX: CGFloat = 0, fromY: CGFloat = 0, fromAngle: CGFloat = 0, fromXScale: CGFloat = 1
    /// Lands and fades instead of joining a pile (Accumulate off).
    var ephemeral = false
    var fadeDelay: CGFloat = 0
    var fadeT: CGFloat = 0

    // Where it rides in the rake, relative to the tine tips
    var carryDX: CGFloat = 0, carryDY: CGFloat = 0

    init(node: SKSpriteNode, size: CGFloat, coverage: CGFloat) {
        self.node = node
        self.size = size
        self.coverage = coverage
        radius = size * coverage * 0.5
        contactOffset = size * coverage * 0.22
    }
}

/// A ledge leaves can pile up on: the bottom of the screen, or the top edge of a window.
/// The pile is a row of columns, each a stack of leaves from the bottom up.
private final class Surface {
    let id: Int
    let frame: CGRect
    let minX: CGFloat
    let baseY: CGFloat
    let colWidth: CGFloat
    let maxHeight: CGFloat
    /// Window ledges shed leaves off their ends; the screen bottom does not.
    let spillsAtEnds: Bool

    var stacks: [[Leaf]]
    var heights: [CGFloat]
    var visible: [Bool]
    var dirty = Set<Int>()
    var count = 0

    init(id: Int, frame: CGRect, minX: CGFloat, maxX: CGFloat, baseY: CGFloat, colWidth: CGFloat, maxHeight: CGFloat, spillsAtEnds: Bool) {
        let n = max(1, Int(((maxX - minX) / colWidth).rounded(.down)))
        self.id = id
        self.frame = frame
        self.minX = minX
        self.baseY = baseY
        self.colWidth = (maxX - minX) / CGFloat(n)
        self.maxHeight = maxHeight
        self.spillsAtEnds = spillsAtEnds
        stacks = Array(repeating: [], count: n)
        heights = Array(repeating: 0, count: n)
        visible = Array(repeating: true, count: n)
    }

    var columns: Int { heights.count }
    var maxX: CGFloat { minX + CGFloat(columns) * colWidth }

    func column(at x: CGFloat) -> Int? {
        let c = Int(((x - minX) / colWidth).rounded(.down))
        return c >= 0 && c < columns ? c : nil
    }

    func centerX(_ c: Int) -> CGFloat { minX + (CGFloat(c) + 0.5) * colWidth }
    func top(_ c: Int) -> CGFloat { baseY + heights[c] }

    /// Height next door for slumping: nil when there is nothing to slide onto,
    /// 0 when a leaf would roll off the end of a window ledge.
    func neighborHeight(_ n: Int) -> CGFloat? {
        if n < 0 || n >= columns { return spillsAtEnds ? 0 : nil }
        return visible[n] ? heights[n] : nil
    }

    var leaves: [Leaf] { stacks.flatMap { $0 } }

    /// A column changed height: it and its neighbours may now be too steep.
    func markDirty(around c: Int) {
        for n in (c - 1)...(c + 1) where n >= 0 && n < columns { dirty.insert(n) }
    }
}

private struct Gust {
    var start: TimeInterval
    var duration: TimeInterval
    var strength: CGFloat
    var dir: CGFloat
    /// Peak wind speed in points per second.
    var speed: CGFloat
    /// How fast the gust front sweeps across the screen.
    var frontSpeed: CGFloat
    /// Share of each column's leaves the gust carries away (0 for a plain breeze).
    var removeFraction: CGFloat
    /// Clear Leaves: strip everything and let nothing settle.
    var clearing: Bool

    static let tail: TimeInterval = 2
}

// MARK: - Scene

/// Falling, piling, blowing leaves for one display.
final class LeafScene: SKScene {
    var crunchEnabled = true
    var cursorProvider: () -> CGPoint = { NSEvent.mouseLocation }
    var toolProvider: () -> ToolInput = { ToolInput() }
    var snapshotPrefix: String?

    private(set) var settings = SceneSettings()
    private var started = false

    /// Bottom-left of this display in global coordinates.
    private let origin: CGPoint
    /// Top of the usable area (below the menu bar), in scene coordinates.
    private let usableTop: CGFloat
    private let art: LeafTextures
    private let audio: CrunchAudio
    private let leafLayer = SKNode()

    private var active: [Leaf] = []
    private var ground: Surface!
    private var windowSurfaces: [Int: Surface] = [:]
    private var stashed: [Int: (surface: Surface, time: TimeInterval)] = [:]
    private var vanished: [Int: (surface: Surface, time: TimeInterval)] = [:]
    private var gusts: [Gust] = []
    private let noise = ValueNoise(seed: UInt64.random(in: 1...UInt64.max))
    private var breezeAmp: CGFloat = 20

    private var lastUpdate: TimeInterval = 0
    private var time: TimeInterval = 0
    private var spawnCarry: CGFloat = 0
    private var restZ: CGFloat = 1
    private var nextBreezeGust: TimeInterval = 12
    private var nextClearingGust: TimeInterval = 70
    private var clearUntil: TimeInterval?
    private var relaxTimer: TimeInterval = 0
    private var cursorLast: CGPoint?
    private var cursorVelocity = CGVector.zero

    private var carried: [Leaf] = []
    private var rakeHead = CGPoint.zero
    private var rakeFacing: CGFloat = 1
    private let rakeCapacity = 36
    private var puffCarry: CGFloat = 0
    private lazy var puffTexture = Self.makePuffTexture()

    private var statsTimer: TimeInterval = 0
    private var frames = 0
    private var nextSnapshot: TimeInterval = 6
    private var snapshotCount = 0
    private var debugClearAt = ProcessInfo.processInfo.environment["RUSTLE_CLEAR_AT"].flatMap(Double.init)

    private static let airborneZ: CGFloat = 5_000_000
    private let colWidth: CGFloat = 12
    /// Steepest step between neighboring columns before leaves slide (the angle of repose).
    private let maxStep: CGFloat = 7
    private let baseLeafSize: CGFloat = 25
    private let debug = ProcessInfo.processInfo.environment["RUSTLE_DEBUG"] != nil

    init(size: CGSize, origin: CGPoint, usableTop: CGFloat, art: LeafTextures, audio: CrunchAudio) {
        self.origin = origin
        self.usableTop = usableTop
        self.art = art
        self.audio = audio
        super.init(size: size)
        backgroundColor = .clear
        scaleMode = .resizeFill
        addChild(leafLayer)
        ground = Surface(id: 0, frame: CGRect(x: 0, y: 0, width: size.width, height: 0),
                         minX: 0, maxX: size.width, baseY: 0, colWidth: colWidth,
                         maxHeight: clamp(size.height * 0.065, 46, 80), spillsAtEnds: false)
        if let at = ProcessInfo.processInfo.environment["RUSTLE_GUST_AT"].flatMap(Double.init) { nextClearingGust = at }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Settings

    func apply(_ new: SceneSettings) {
        let old = settings
        settings = new
        switch new.breeze {
        case .calm: breezeAmp = 7
        case .breezy: breezeAmp = 20
        case .gusty: breezeAmp = 34
        }
        if !started || (old.fall == .off && new.fall != .off) { prewarm() }
        started = true
        if old.accumulate && !new.accumulate { fadeAllResting(stagger: 2.5) }
        if !new.onWindows { dropAllWindowSurfaces() }
        if !new.windClears { gusts.removeAll { $0.removeFraction > 0 && !$0.clearing } }
        if new.windClears && !old.windClears { nextClearingGust = time + .random(in: 20...45) }
        wake()
    }

    /// Clear Leaves: a big gust sweeps across and carries the whole pile away.
    func clearAll() {
        for stash in stashed.values { discard(stash.surface) }
        stashed.removeAll()
        guard totalResting > 0 else { return }
        gusts.append(Gust(start: time, duration: 4.5, strength: 1, dir: randomSign(), speed: 620,
                          frontSpeed: 1300, removeFraction: 1, clearing: true))
        clearUntil = time + 7
        wake()
    }

    /// Fills the bottom of the screen at once (debugging and demos).
    func prefill(_ count: Int) {
        for _ in 0..<count {
            let leaf = makeLeaf()
            leaf.x = rnd(0, size.width - 0.01)
            leaf.y = baseLeafSize
            leaf.angle = rnd(-.pi, .pi)
            render(leaf)
            leafLayer.addChild(leaf.node)
            if let c = ground.column(at: leaf.x) { land(leaf, on: ground, column: c) }
            leaf.settleT = 1
        }
    }

    private func wake() {
        if let view, view.isPaused, !(view.window?.isVisible == false) { view.isPaused = false }
    }

    // MARK: Frame loop

    override func update(_ currentTime: TimeInterval) {
        let raw = lastUpdate == 0 ? 1.0 / 60 : currentTime - lastUpdate
        lastUpdate = currentTime
        // After a pause the cursor may have moved anywhere; don't read that as a sweep.
        if raw > 0.25 { cursorLast = nil }
        let dt = min(max(raw, 0.0005), 1.0 / 20)
        time += dt
        let d = CGFloat(dt)

        scheduleGusts()
        spawn(d)
        handlePointer(d)
        liftWithGusts(d)
        stepLeaves(d)

        relaxTimer += dt
        if relaxTimer >= 0.08 {
            relaxTimer = 0
            relax(ground)
            for surface in windowSurfaces.values { relax(surface) }
        }
        if let until = clearUntil, time >= until {
            clearUntil = nil
            fadeAllResting(stagger: 1.2)
        }
        adjustFrameRate()
        if debug { debugTick(dt) }
    }

    private func adjustFrameRate() {
        guard let view else { return }
        let busy = settings.fall != .off || !active.isEmpty || !gusts.isEmpty || toolProvider().tool != .none
        let fps = busy ? (settings.savePower ? 30 : 60) : 15
        if view.preferredFramesPerSecond != fps { view.preferredFramesPerSecond = fps }
        if !busy && totalResting == 0 && stashed.isEmpty && vanished.isEmpty { view.isPaused = true }
    }

    private var totalResting: Int {
        windowSurfaces.values.reduce(ground.count) { $0 + $1.count }
    }

    /// How full the bottom pile is, 0...1.
    private var pileFill: CGFloat {
        let capacity = CGFloat(ground.columns) * ground.maxHeight / 4.2
        return clamp(CGFloat(ground.count) / max(1, capacity), 0, 1)
    }

    // MARK: Spawning

    private func spawnRate() -> CGFloat {
        let perThousandPoints: CGFloat
        switch settings.fall {
        case .off: return 0
        case .light: perThousandPoints = 0.35
        case .steady: perThousandPoints = 1.0
        case .heavy: perThousandPoints = 2.7
        case .variable: perThousandPoints = 0.12 + 2.6 * pow(noise.at(time / 140 + 7), 1.6)
        }
        return perThousandPoints * size.width / 1000 * (settings.savePower ? 0.75 : 1)
    }

    private func spawn(_ dt: CGFloat) {
        spawnCarry += spawnRate() * dt
        while spawnCarry >= 1 {
            spawnCarry -= 1
            spawnLeaf(prewarm: false)
        }
    }

    /// Fills the sky right away so the first leaves don't take half a minute to arrive.
    private func prewarm() {
        let rate = spawnRate()
        guard rate > 0 else { return }
        let count = Int(rate * size.height / 55 * 0.75)
        for _ in 0..<min(count, 250) { spawnLeaf(prewarm: true) }
    }

    private func makeLeaf() -> Leaf {
        let i = Int.random(in: 0..<art.textures.count)
        let s = baseLeafSize * rnd(0.75, 1.4)
        let node = SKSpriteNode(texture: art.textures[i], size: CGSize(width: s, height: s))
        node.color = .black
        let leaf = Leaf(node: node, size: s, coverage: art.coverages[i])
        leaf.fallSpeed = rnd(46, 88)
        leaf.swayAmp = rnd(18, 55)
        leaf.swayFreq = rnd(1.1, 2.3)
        leaf.swayPhase = rnd(0, 2 * .pi)
        leaf.tilt = rnd(0.3, 0.8)
        leaf.tumbler = chance(0.3)
        leaf.baseFlipRate = (leaf.tumbler ? rnd(2.5, 6) : rnd(0.7, 1.8)) * randomSign()
        leaf.flipRate = leaf.baseFlipRate
        leaf.flip = rnd(0, 2 * .pi)
        leaf.angle = rnd(-.pi, .pi)
        leaf.drag = rnd(1.8, 2.8)
        leaf.windCatch = rnd(0.8, 1.1)
        leaf.shade = rnd(0, 0.14)
        node.zPosition = Self.airborneZ
        return leaf
    }

    private func spawnLeaf(prewarm: Bool) {
        guard active.count < 900 else { return }
        let leaf = makeLeaf()
        let fallTime = size.height / (leaf.fallSpeed * 0.8)
        let drift = baseWind(size.width / 2) * fallTime * 0.8
        leaf.x = rnd(-0.04, 1.04) * size.width - drift
        leaf.y = prewarm ? rnd(0.12, 1) * size.height : size.height + leaf.size
        leaf.vx = baseWind(leaf.x)
        leaf.vy = -leaf.fallSpeed * 0.8
        if prewarm {
            leaf.alpha = 0
            leaf.node.alpha = 0
        }
        render(leaf)
        leafLayer.addChild(leaf.node)
        activate(leaf)
    }

    // MARK: Wind

    private func baseWind(_ x: CGFloat) -> CGFloat {
        let slow = noise.at(time * 0.02) * 2 - 1
        let local = noise.at(Double(x) / 650 + time * 0.09 + 40) * 2 - 1
        return breezeAmp * (slow + 0.35 * local)
    }

    private func gustFactor(_ g: Gust, x: CGFloat) -> CGFloat {
        let elapsed = time - g.start
        guard elapsed >= 0, elapsed <= g.duration + Gust.tail else { return 0 }
        let travel = CGFloat(elapsed) * g.frontSpeed
        // Distance behind the gust front as it sweeps across the screen.
        let behind = g.dir > 0 ? travel - 300 - x : x - (size.width + 300 - travel)
        guard behind > 0 else { return 0 }
        let envelope: CGFloat = elapsed < g.duration ? 1 : CGFloat(1 - (elapsed - g.duration) / Gust.tail)
        let flutter = 0.8 + 0.4 * noise.at(Double(x) / 260 + elapsed * 1.7 + 13)
        return g.strength * smoothstep(0, 280, behind) * envelope * flutter
    }

    private func windAt(x: CGFloat) -> CGPoint {
        var wx = baseWind(x), wy: CGFloat = 0
        for g in gusts {
            let f = gustFactor(g, x: x)
            if f > 0 {
                wx += g.dir * g.speed * f
                // Patchy updrafts loft some leaves high while others skitter low.
                let updraft: CGFloat = g.removeFraction > 0 ? 120 : 45
                wy += f * updraft * (noise.at(Double(x) / 380 + time * 0.8 + 91) - 0.3)
            }
        }
        return CGPoint(x: wx, y: wy)
    }

    private var clearingActive: Bool { gusts.contains { $0.clearing } }

    private func scheduleGusts() {
        gusts.removeAll { time > $0.start + $0.duration + Gust.tail }

        if settings.breeze != .calm, time >= nextBreezeGust {
            let gusty = settings.breeze == .gusty
            let prevailing: CGFloat = baseWind(size.width / 2) >= 0 ? 1 : -1
            gusts.append(Gust(start: time, duration: .random(in: 2.5...5.5), strength: rnd(0.45, 1),
                              dir: chance(0.75) ? prevailing : -prevailing, speed: gusty ? 200 : 120,
                              frontSpeed: rnd(600, 900), removeFraction: 0, clearing: false))
            nextBreezeGust = time + (gusty ? .random(in: 10...28) : .random(in: 22...55))
        }

        if settings.windClears, time >= nextClearingGust {
            let fill = pileFill
            if fill > 0.015 || windowSurfaces.values.contains(where: { $0.count > 0 }) {
                gusts.append(Gust(start: time, duration: .random(in: 4...7), strength: 0.8 + 0.2 * fill,
                                  dir: randomSign(), speed: rnd(420, 560), frontSpeed: rnd(800, 1100),
                                  removeFraction: 0.12 + 0.45 * fill, clearing: false))
            }
            // A fuller pile draws stronger, more frequent gusts, so it settles at a pleasant depth.
            nextClearingGust = time + .random(in: 45...100) * Double(1.25 - 0.75 * fill)
        }
    }

    private func liftWithGusts(_ dt: CGFloat) {
        for g in gusts where g.removeFraction > 0 {
            liftColumns(of: ground, gust: g, dt: dt)
            for surface in windowSurfaces.values { liftColumns(of: surface, gust: g, dt: dt) }
        }
    }

    private func liftColumns(of s: Surface, gust g: Gust, dt: CGFloat) {
        guard s.count > 0 else { return }
        for c in 0..<s.columns where s.visible[c] {
            let n = s.stacks[c].count
            guard n > 0 else { continue }
            let f = gustFactor(g, x: s.centerX(c))
            guard f > 0.15 else { continue }
            let rate = g.clearing ? max(CGFloat(n) / 1.2, 5) : g.removeFraction * CGFloat(n) / CGFloat(g.duration)
            if chance(rate * f * dt), let leaf = s.stacks[c].last {
                detach(leaf)
                leaf.vx = g.dir * rnd(90, 280) * f
                leaf.vy = rnd(40, 190) * f + 20
                launch(leaf, spin: f)
            }
        }
    }

    // MARK: Leaf motion

    private func activate(_ leaf: Leaf) {
        guard !leaf.isActive else { return }
        leaf.isActive = true
        active.append(leaf)
    }

    private func stepLeaves(_ dt: CGFloat) {
        var i = 0
        while i < active.count {
            let leaf = active[i]
            switch leaf.state {
            case .airborne: stepAirborne(leaf, dt)
            case .settling: stepSettling(leaf, dt)
            case .fading: stepFading(leaf, dt)
            case .carried: stepCarried(leaf, dt)
            case .resting, .removed: break
            }
            if leaf.state == .resting || leaf.state == .removed {
                leaf.isActive = false
                active.swapAt(i, active.count - 1)
                active.removeLast()
            } else {
                i += 1
            }
        }
    }

    private func stepAirborne(_ l: Leaf, _ dt: CGFloat) {
        let wind = windAt(x: l.x)
        // A falling leaf swings like a pendulum: fastest and lowest mid-swing, slowing at the ends.
        l.swayPhase += l.swayFreq * dt
        let c = cos(l.swayPhase)
        let targetVX = wind.x * l.windCatch + l.swayAmp * c
        let targetVY = -l.fallSpeed * (0.35 + 0.9 * c * c) + wind.y
        let k = 1 - exp(-l.drag * dt)
        l.vx += (targetVX - l.vx) * k
        l.vy += (targetVY - l.vy) * k
        let previousBottom = l.y - l.contactOffset
        l.x += l.vx * dt
        l.y += l.vy * dt

        l.spin += (l.tilt * l.swayFreq * c - l.spin) * (1 - exp(-2.5 * dt))
        l.angle += l.spin * dt
        l.flipRate += (l.baseFlipRate - l.flipRate) * (1 - exp(-1.5 * dt))
        l.flip += l.flipRate * dt
        let wobble = 0.8 + 0.2 * cos(l.flip)
        let tumble = l.tumbler ? 1 : smoothstep(1.5, 4, abs(l.flipRate))
        l.xScale = wobble + (cos(l.flip) - wobble) * tumble
        if l.alpha < 1 {
            l.alpha = min(1, l.alpha + dt * 1.5)
            l.node.alpha = l.alpha
        }
        if l.depthShade > 0.001 { l.depthShade *= exp(-4 * dt) }
        render(l)

        if l.vy < 0 {
            let bottom = l.y - l.contactOffset
            if settings.onWindows {
                for s in windowSurfaces.values where s.id != l.ignoredSurface && l.x >= s.minX && l.x < s.maxX {
                    guard let col = s.column(at: l.x), s.visible[col] else { continue }
                    let top = s.top(col)
                    if previousBottom >= top - 0.5 && bottom <= top {
                        land(l, on: s, column: col)
                        return
                    }
                }
            }
            if let col = ground.column(at: l.x), bottom <= ground.top(col) {
                land(l, on: ground, column: col)
                return
            }
        }
        if l.y < -60 || l.x < -180 || l.x > size.width + 180 || l.y > size.height + 400 {
            remove(l)
        }
    }

    private func stepSettling(_ l: Leaf, _ dt: CGFloat) {
        l.settleT = min(1, l.settleT + dt / l.settleDuration)
        let e = 1 - pow(1 - l.settleT, 3)
        l.x = l.fromX + (l.restX - l.fromX) * e
        l.y = l.fromY + (l.restY - l.fromY) * e
        l.angle = l.fromAngle + (l.restAngle - l.fromAngle) * e
        l.xScale = l.fromXScale + (l.restXScale - l.fromXScale) * e
        let targetShade = l.surface.map { 0.24 * (1 - smoothstep(0, 34, l.restY - $0.baseY)) } ?? 0
        l.depthShade = l.fromDepthShade + (targetShade - l.fromDepthShade) * e
        if l.alpha < 1 {
            l.alpha = min(1, l.alpha + dt * 1.5)
            l.node.alpha = l.alpha
        }
        render(l)
        if l.settleT >= 1 {
            if l.ephemeral {
                l.state = .fading
                l.fadeT = 0
            } else {
                l.state = .resting
            }
        }
    }

    private func stepFading(_ l: Leaf, _ dt: CGFloat) {
        if l.fadeDelay > 0 {
            l.fadeDelay -= dt
            return
        }
        l.fadeT += dt / 1.2
        l.node.alpha = l.alpha * max(0, 1 - l.fadeT)
        if l.fadeT >= 1 { remove(l) }
    }

    private func render(_ l: Leaf) {
        l.node.position = CGPoint(x: l.x, y: l.y)
        l.node.zRotation = l.angle
        var xs = l.xScale
        if abs(xs) < 0.05 { xs = xs < 0 ? -0.05 : 0.05 }
        l.node.xScale = xs
        // The underside of a leaf is duller.
        l.node.colorBlendFactor = min(0.6, l.shade + l.depthShade + (xs < 0 ? 0.22 : 0))
    }

    private func beginSettle(_ l: Leaf, duration: CGFloat) {
        l.fromX = l.x
        l.fromY = l.y
        l.fromAngle = l.angle
        l.fromXScale = l.xScale
        l.fromDepthShade = l.depthShade
        l.settleT = 0
        l.settleDuration = max(0.05, duration)
        l.state = .settling
        activate(l)
    }

    /// Sends a leaf back into the air with a lively spin.
    private func launch(_ l: Leaf, spin strength: CGFloat) {
        l.spin = rnd(-9, 9) * strength
        l.flipRate = randomSign() * rnd(5, 12) * strength
        l.swayPhase = rnd(0, 2 * .pi)
        l.state = .airborne
        l.ephemeral = false
        l.ignoredSurface = nil
        l.node.zPosition = Self.airborneZ
        activate(l)
    }

    private func remove(_ l: Leaf) {
        if l.surface != nil { detach(l) }
        l.state = .removed
        l.node.removeFromParent()
    }

    // MARK: Piles

    private func restPose(for l: Leaf) -> (angle: CGFloat, xScale: CGFloat, halfExtent: CGFloat, thickness: CGFloat) {
        let sign: CGFloat = l.xScale < 0 ? -1 : 1
        var angle: CGFloat
        let xs: CGFloat
        if chance(0.8) {
            // Most leaves lie flat: turned sideways and foreshortened, as seen from the side.
            angle = (sin(l.angle) >= 0 ? CGFloat.pi / 2 : -CGFloat.pi / 2) + rnd(-0.5, 0.5)
            xs = sign * rnd(0.32, 0.7)
        } else {
            angle = l.angle + rnd(-0.6, 0.6)
            xs = sign * rnd(0.65, 1)
        }
        angle = l.angle + (angle - l.angle).remainder(dividingBy: 2 * .pi)
        let halfLength = l.radius
        let halfWidth = halfLength * 0.78 * abs(xs)
        let halfExtent = sqrt(pow(halfLength * cos(angle), 2) + pow(halfWidth * sin(angle), 2))
        return (angle, xs, halfExtent, clamp(halfExtent * 0.8, 3.2, 7))
    }

    private func land(_ l: Leaf, on s: Surface, column: Int) {
        let wind = windAt(x: l.x).x
        if clearingActive || (settings.windClears && abs(wind) > 170) {
            // Too windy to settle: the leaf skitters along instead.
            l.vy = rnd(30, 120)
            l.vx = wind * rnd(0.4, 0.8)
            l.flipRate = randomSign() * rnd(4, 9)
            return
        }

        let pose = restPose(for: l)
        var c = column
        var slid = false
        // Slide down any slope steeper than the angle of repose.
        for _ in 0..<12 {
            let here = s.heights[c] + pose.thickness
            var best = c, lowest = here
            for n in [c - 1, c + 1] {
                if let h = s.neighborHeight(n), h < lowest { lowest = h; best = n }
            }
            guard best != c, here - lowest > maxStep * 1.3 else { break }
            if best < 0 || best >= s.columns {
                rollOff(l, from: s, toward: best < 0 ? -1 : 1)
                return
            }
            c = best
            slid = true
        }

        let restX = slid ? s.centerX(c) + rnd(-0.45, 0.45) * s.colWidth : l.x
        if !settings.accumulate {
            l.ephemeral = true
            l.restX = restX
            l.restY = s.top(c) + pose.halfExtent * 0.7
            l.restAngle = pose.angle
            l.restXScale = pose.xScale
            l.fadeDelay = rnd(1.2, 3)
            beginSettle(l, duration: 0.35)
            return
        }

        if s.heights[c] + pose.thickness > s.maxHeight {
            if s === ground {
                compact(s, column: c, needed: pose.thickness)
            } else {
                rollOff(l, from: s, toward: s.centerX(c) < s.frame.midX ? -1 : 1)
                return
            }
        }

        l.surface = s
        l.column = c
        l.thickness = pose.thickness
        l.restX = restX
        l.restY = s.top(c) + pose.halfExtent * 0.7 + rnd(-1, 1)
        l.restAngle = pose.angle
        l.restXScale = pose.xScale
        s.stacks[c].append(l)
        s.heights[c] += pose.thickness
        s.count += 1
        s.dirty.insert(c)
        l.node.zPosition = nextRestZ()
        beginSettle(l, duration: slid ? 0.5 : rnd(0.25, 0.4))
    }

    /// A full or steep window ledge sheds the leaf: it tips off and falls past.
    private func rollOff(_ l: Leaf, from s: Surface, toward dir: CGFloat) {
        l.ignoredSurface = s.id
        l.vx = dir * rnd(40, 90)
        l.vy = rnd(10, 40)
    }

    /// Takes a leaf out of its pile; the leaves above it sink into the gap.
    private func detach(_ l: Leaf) {
        guard let s = l.surface else { return }
        let c = l.column
        l.surface = nil
        l.column = -1
        guard c >= 0, c < s.columns, let i = s.stacks[c].firstIndex(where: { $0 === l }) else { return }
        s.stacks[c].remove(at: i)
        s.heights[c] = max(0, s.heights[c] - l.thickness)
        s.count -= 1
        s.markDirty(around: c)
        for j in i..<s.stacks[c].count {
            let above = s.stacks[c][j]
            above.restY -= l.thickness
            beginSettle(above, duration: 0.18)
        }
    }

    /// The bottom pile is full here: the oldest, buried leaves give way to make room.
    private func compact(_ s: Surface, column c: Int, needed: CGFloat) {
        var removed: CGFloat = 0
        while s.heights[c] - removed + needed > s.maxHeight, !s.stacks[c].isEmpty {
            let bottom = s.stacks[c].removeFirst()
            removed += bottom.thickness
            s.count -= 1
            bottom.surface = nil
            remove(bottom)
        }
        guard removed > 0 else { return }
        s.heights[c] = max(0, s.heights[c] - removed)
        s.markDirty(around: c)
        for leaf in s.stacks[c] {
            leaf.restY -= removed
            beginSettle(leaf, duration: 0.6)
        }
    }

    /// Lets steep spots collapse after leaves were kicked out or blown away.
    private func relax(_ s: Surface) {
        guard !s.dirty.isEmpty else { return }
        let columns = s.dirty
        s.dirty.removeAll(keepingCapacity: true)
        var moves = 0
        for c in columns where c >= 0 && c < s.columns && s.visible[c] {
            guard moves < 10 else {
                s.dirty.insert(c)
                continue
            }
            guard let top = s.stacks[c].last else { continue }
            var target = 0, lowest = s.heights[c]
            for n in [c - 1, c + 1] {
                if let h = s.neighborHeight(n), h < lowest { lowest = h; target = n - c }
            }
            guard target != 0, s.heights[c] - lowest > maxStep * 1.3 else { continue }
            detach(top)
            top.vx = CGFloat(target) * rnd(35, 80)
            top.vy = rnd(10, 35)
            launch(top, spin: 0.25)
            moves += 1
        }
    }

    private func fadeAllResting(stagger: CGFloat) {
        for stash in stashed.values { discard(stash.surface) }
        stashed.removeAll()
        for s in [ground!] + Array(windowSurfaces.values) + vanished.values.map(\.surface) {
            for c in 0..<s.columns {
                for leaf in s.stacks[c] {
                    leaf.surface = nil
                    leaf.column = -1
                    leaf.state = .fading
                    leaf.fadeT = 0
                    leaf.fadeDelay = rnd(0, stagger)
                    activate(leaf)
                }
                s.stacks[c].removeAll()
                s.heights[c] = 0
            }
            s.count = 0
            s.dirty.removeAll()
        }
    }

    private func nextRestZ() -> CGFloat {
        restZ += 1
        if restZ > 4_000_000 {
            // Keep z values well inside Float precision on very long runs.
            let surfaces = [ground!] + Array(windowSurfaces.values) + stashed.values.map(\.surface)
                + vanished.values.map(\.surface)
            let resting = surfaces.flatMap { $0.leaves }
                .sorted { $0.node.zPosition < $1.node.zPosition }
            for (i, leaf) in resting.enumerated() { leaf.node.zPosition = CGFloat(i + 1) }
            restZ = CGFloat(resting.count + 1)
        }
        return restZ
    }

    // MARK: Cursor

    private func handlePointer(_ dt: CGFloat) {
        let global = cursorProvider()
        let p = CGPoint(x: global.x - origin.x, y: global.y - origin.y)
        defer { cursorLast = p }
        let tool = toolProvider()
        if tool.tool != .rake && !carried.isEmpty { releaseCarried() }
        guard let last = cursorLast else { return }
        let dx = p.x - last.x, dy = p.y - last.y
        if abs(dx) > 600 || abs(dy) > 600 {
            cursorVelocity = .zero
            if !carried.isEmpty { releaseCarried() }
            return
        }
        let blend = 1 - exp(-dt * 30)
        cursorVelocity.dx += (dx / dt - cursorVelocity.dx) * blend
        cursorVelocity.dy += (dy / dt - cursorVelocity.dy) * blend
        let onScreen = p.x > -40 && p.x < size.width + 40 && p.y > -40 && p.y < size.height + 40
        switch tool.tool {
        case .none:
            if onScreen && (dx != 0 || dy != 0) { kickWithCursor(from: last, to: p) }
        case .rake:
            rake(from: last, to: p, tool: tool, onScreen: onScreen)
        case .blower:
            if onScreen { blow(at: p, tool: tool, dt: dt) }
        }
    }

    private func kickWithCursor(from last: CGPoint, to p: CGPoint) {
        let speed = hypot(cursorVelocity.dx, cursorVelocity.dy)
        guard speed > 30 else { return }

        if speed > 60 { nudgeAirborne(near: p) }

        let radius = 14 + min(speed * 0.012, 14)
        var hits: [Leaf] = []
        collectHits(on: ground, from: last, to: p, radius: radius, into: &hits)
        if settings.onWindows {
            for s in windowSurfaces.values { collectHits(on: s, from: last, to: p, radius: radius, into: &hits) }
        }
        guard !hits.isEmpty else { return }

        let maxKicks = min(hits.count, 3 + Int(speed / 70), 28)
        if hits.count > maxKicks { hits.sort { $0.y > $1.y } }
        for leaf in hits.prefix(maxKicks) { kick(leaf, from: last, to: p, speed: speed) }

        if crunchEnabled {
            let intensity = clamp(0.08 + CGFloat(maxKicks) / 12 * 0.6 + speed / 2200 * 0.4, 0, 1)
            let pan = clamp(p.x / size.width * 2 - 1, -1, 1)
            audio.crunch(intensity: Float(intensity), pan: Float(pan))
        }
    }

    private func collectHits(on s: Surface, from a: CGPoint, to b: CGPoint, radius: CGFloat, into hits: inout [Leaf]) {
        guard s.count > 0 else { return }
        let minY = min(a.y, b.y) - radius - 20, maxY = max(a.y, b.y) + radius + 20
        guard maxY >= s.baseY - 10, minY <= s.baseY + s.maxHeight + 20 else { return }
        let minX = min(a.x, b.x) - radius - 16, maxX = max(a.x, b.x) + radius + 16
        guard let c0 = s.column(at: max(minX, s.minX)), let c1 = s.column(at: min(maxX, s.maxX - 0.01)), c0 <= c1 else { return }
        for c in c0...c1 where s.visible[c] {
            for leaf in s.stacks[c].reversed() {
                if leaf.y + leaf.radius < minY { break }
                let q = closestPoint(onSegment: a, b, to: CGPoint(x: leaf.x, y: leaf.y))
                if hypot(leaf.x - q.x, leaf.y - q.y) < radius + leaf.radius * 0.55 { hits.append(leaf) }
            }
        }
    }

    private func kick(_ l: Leaf, from a: CGPoint, to b: CGPoint, speed: CGFloat) {
        detach(l)
        let q = closestPoint(onSegment: a, b, to: CGPoint(x: l.x, y: l.y))
        var nx = l.x - q.x, ny = l.y - q.y
        let len = hypot(nx, ny)
        if len > 0.01 { nx /= len; ny /= len } else { nx = 0; ny = 1 }
        let strength = clamp(speed / 700, 0.3, 1.6)
        l.vx = cursorVelocity.dx * rnd(0.25, 0.6) + nx * rnd(40, 140) * strength
        l.vy = max(0, cursorVelocity.dy) * rnd(0.2, 0.45) + rnd(70, 240) * strength + max(0, ny) * 60 * strength
        let v = hypot(l.vx, l.vy)
        if v > 1300 {
            l.vx *= 1300 / v
            l.vy *= 1300 / v
        }
        launch(l, spin: strength)
    }

    /// Falling leaves get caught in the cursor's wake.
    private func nudgeAirborne(near p: CGPoint) {
        for leaf in active where leaf.state == .airborne {
            let dx = leaf.x - p.x, dy = leaf.y - p.y
            let d2 = dx * dx + dy * dy
            guard d2 < 6400 else { continue }
            let falloff = 1 - sqrt(d2) / 80
            leaf.vx += cursorVelocity.dx * 0.12 * falloff
            leaf.vy += cursorVelocity.dy * 0.12 * falloff
            leaf.spin += rnd(-3, 3) * falloff
        }
    }

    // MARK: Rake

    /// The highest pile or ledge top just under the rake, if the tines are low enough to touch it.
    private func supportTop(under p: CGPoint) -> CGFloat? {
        var best: CGFloat?
        if let c = ground.column(at: p.x) { best = ground.top(c) }
        if settings.onWindows {
            for s in windowSurfaces.values {
                guard let c = s.column(at: p.x), s.visible[c] else { continue }
                let top = s.top(c)
                if top <= p.y + 10, top > (best ?? -.infinity) { best = top }
            }
        }
        guard let top = best, p.y - top < 28 else { return nil }
        return top
    }

    private func rake(from last: CGPoint, to p: CGPoint, tool: ToolInput, onScreen: Bool) {
        rakeHead = p
        rakeFacing = tool.facing
        // Leaves only stay in the tines while the rake is pressed against something.
        guard onScreen, tool.pressed, supportTop(under: p) != nil else {
            if !carried.isEmpty { releaseCarried() }
            return
        }
        let speed = hypot(cursorVelocity.dx, cursorVelocity.dy)
        if speed > 12 {
            var hits: [Leaf] = []
            let minX = min(last.x, p.x) - 30, maxX = max(last.x, p.x) + 30
            let minY = min(last.y, p.y) - 20, maxY = max(last.y, p.y) + 14
            gatherLeaves(on: ground, minX: minX, maxX: maxX, minY: minY, maxY: maxY, into: &hits)
            if settings.onWindows {
                for s in windowSurfaces.values { gatherLeaves(on: s, minX: minX, maxX: maxX, minY: minY, maxY: maxY, into: &hits) }
            }
            hits.sort { $0.y > $1.y }
            for leaf in hits.prefix(8) {
                detach(leaf)
                if carried.count < rakeCapacity {
                    leaf.state = .carried
                    leaf.ephemeral = false
                    leaf.carryDX = rnd(-4, 26)
                    leaf.carryDY = rnd(-3, 12) + CGFloat(carried.count) * 0.4
                    leaf.node.zPosition = Self.airborneZ
                    carried.append(leaf)
                    activate(leaf)
                } else {
                    // The rake is full: extra leaves tumble along ahead of it.
                    leaf.vx = cursorVelocity.dx * rnd(0.6, 1.0)
                    leaf.vy = rnd(30, 90)
                    launch(leaf, spin: 0.4)
                }
            }
        }
        if !carried.isEmpty && speed > 8 && crunchEnabled {
            let intensity = clamp(CGFloat(carried.count) / CGFloat(rakeCapacity) * 0.6 + speed / 1500 * 0.4, 0, 1)
            audio.rake(intensity: Float(intensity), pan: Float(clamp(p.x / size.width * 2 - 1, -1, 1)))
        }
    }

    private func gatherLeaves(on s: Surface, minX: CGFloat, maxX: CGFloat, minY: CGFloat, maxY: CGFloat, into hits: inout [Leaf]) {
        guard s.count > 0, maxY >= s.baseY - 10, minY <= s.baseY + s.maxHeight + 10,
              let c0 = s.column(at: max(minX, s.minX)), let c1 = s.column(at: min(maxX, s.maxX - 0.01)), c0 <= c1 else { return }
        for c in c0...c1 where s.visible[c] {
            for leaf in s.stacks[c].reversed() {
                if leaf.y < minY { break }
                if leaf.y <= maxY { hits.append(leaf) }
            }
        }
    }

    private func stepCarried(_ l: Leaf, _ dt: CGFloat) {
        let tx = rakeHead.x + rakeFacing * l.carryDX
        let ty = rakeHead.y + l.carryDY
        let k = 1 - exp(-16 * dt)
        let nx = l.x + (tx - l.x) * k, ny = l.y + (ty - l.y) * k
        l.vx = (nx - l.x) / dt
        l.vy = (ny - l.y) / dt
        l.x = nx
        l.y = ny
        // Leaves roll and jostle in the tines as they're dragged.
        l.angle -= clamp(l.vx * 0.004, -3, 3) * dt
        let flat: CGFloat = l.xScale < 0 ? -0.6 : 0.6
        l.xScale += (flat - l.xScale) * k * 0.3
        if l.depthShade > 0.001 { l.depthShade *= exp(-4 * dt) }
        render(l)
    }

    /// Lets go of everything in the rake; the leaves settle where they are.
    private func releaseCarried() {
        for leaf in carried where leaf.state == .carried {
            leaf.vx = clamp(leaf.vx * 0.4, -300, 300) + rnd(-15, 15)
            leaf.vy = rnd(-10, 25)
            leaf.ignoredSurface = nil
            leaf.state = .airborne
        }
        carried.removeAll()
    }

    // MARK: Leaf blower

    private func blow(at p: CGPoint, tool: ToolInput, dt: CGFloat) {
        let pan = Float(clamp(p.x / size.width * 2 - 1, -1, 1))
        // Only the display under the cursor drives the blower's sound.
        if crunchEnabled && CGRect(origin: .zero, size: size).contains(p) {
            audio.blower(level: tool.pressed ? 1 : 0, pan: pan)
        }
        guard tool.pressed else { return }
        let a = tool.blowerAngle
        let dir = CGVector(dx: tool.facing * cos(a), dy: -sin(a))
        let length: CGFloat = 380
        spawnPuffs(from: p, dir: dir, dt: dt)

        // Where the jet's axis meets the ground: from there the air fans out along the pile.
        var impact: CGPoint?
        if dir.dy < -0.05 {
            let groundY = ground.column(at: p.x).map { ground.top($0) } ?? 0
            let along = (p.y - groundY) / -dir.dy
            if along > 0 && along < length { impact = CGPoint(x: p.x + dir.dx * along, y: groundY) }
        }
        let impactStrength = impact.map { 1 - hypot($0.x - p.x, $0.y - p.y) / length } ?? 0

        func strength(at q: CGPoint) -> CGFloat {
            let rx = q.x - p.x, ry = q.y - p.y
            var s: CGFloat = 0
            let along = rx * dir.dx + ry * dir.dy
            if along > -8 && along < length {
                let perp = abs(rx * dir.dy - ry * dir.dx)
                let width = 16 + max(0, along) * 0.32
                if perp < width { s = (1 - max(0, along) / length) * (1 - perp / width).squareRoot() }
            }
            if let impact, impactStrength > 0 {
                let ahead = (q.x - impact.x) * tool.facing
                if ahead > -30 && ahead < 260 && q.y - impact.y < 30 {
                    s = max(s, impactStrength * 0.8 * (1 - max(0, ahead) / 260))
                }
            }
            return s
        }

        for leaf in active where leaf.state == .airborne {
            let s = strength(at: CGPoint(x: leaf.x, y: leaf.y))
            guard s > 0 else { continue }
            leaf.vx += dir.dx * 2600 * s * dt
            leaf.vy += (dir.dy * 2600 + 900) * s * dt
            leaf.spin += rnd(-40, 40) * s * dt
            leaf.flipRate += randomSign() * 30 * s * dt
        }

        var lifted = 0
        let end = CGPoint(x: p.x + dir.dx * length, y: p.y + dir.dy * length)
        let reach = 16 + length * 0.32
        var minX = min(p.x, end.x) - reach, maxX = max(p.x, end.x) + reach
        if let impact {
            minX = min(minX, impact.x - 260)
            maxX = max(maxX, impact.x + 260)
        }
        for s in [ground!] + Array(windowSurfaces.values) where s.count > 0 {
            guard let c0 = s.column(at: max(minX, s.minX)), let c1 = s.column(at: min(maxX, s.maxX - 0.01)), c0 <= c1 else { continue }
            var candidates: [(Leaf, CGFloat)] = []
            for c in c0...c1 where s.visible[c] {
                // Only the top few leaves of each column feel the air.
                for leaf in s.stacks[c].suffix(3) {
                    let st = strength(at: CGPoint(x: leaf.x, y: leaf.y))
                    if st > 0.02 && chance(16 * st * dt) { candidates.append((leaf, st)) }
                }
            }
            for (leaf, st) in candidates.prefix(30) {
                detach(leaf)
                leaf.vx = dir.dx * rnd(250, 520) * st + tool.facing * rnd(120, 300) * st
                leaf.vy = rnd(70, 230) * st + 20
                launch(leaf, spin: st + 0.3)
                lifted += 1
            }
        }
        if lifted > 0 && crunchEnabled {
            audio.crunch(intensity: Float(min(0.55, 0.14 + CGFloat(lifted) * 0.05)), pan: pan)
        }
    }

    /// Faint wisps of air streaming from the nozzle.
    private func spawnPuffs(from p: CGPoint, dir: CGVector, dt: CGFloat) {
        puffCarry += 36 * dt
        while puffCarry >= 1 {
            puffCarry -= 1
            let puff = SKSpriteNode(texture: puffTexture, size: CGSize(width: 14, height: 14))
            let start = rnd(4, 24)
            let side = rnd(-5, 5)
            puff.position = CGPoint(x: p.x + dir.dx * start - dir.dy * side, y: p.y + dir.dy * start + dir.dx * side)
            puff.alpha = rnd(0.10, 0.2)
            puff.zPosition = Self.airborneZ + 10
            puff.setScale(0.6)
            let travel = rnd(170, 260)
            let spread = rnd(-0.22, 0.22)
            let move = SKAction.moveBy(x: (dir.dx - dir.dy * spread) * travel, y: (dir.dy + dir.dx * spread) * travel, duration: 0.45)
            move.timingMode = .easeOut
            puff.run(.sequence([.group([move, .scale(to: rnd(1.6, 2.4), duration: 0.45), .fadeOut(withDuration: 0.45)]),
                                .removeFromParent()]))
            leafLayer.addChild(puff)
        }
    }

    private static func makePuffTexture() -> SKTexture {
        let px = 32
        let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors = [CGColor(gray: 1, alpha: 0.9), CGColor(gray: 1, alpha: 0)]
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1])!
        let c = CGPoint(x: CGFloat(px) / 2, y: CGFloat(px) / 2)
        ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(px) / 2, options: [])
        return SKTexture(cgImage: ctx.makeImage()!)
    }

    // MARK: Windows

    /// Reconciles window ledges with the latest window list (front to back).
    func updateWindows(_ windows: [TrackedWindow], spaceChangedAt: TimeInterval) {
        guard settings.onWindows else {
            dropAllWindowSurfaces()
            return
        }
        let now = CACurrentMediaTime()
        let screenRect = CGRect(origin: origin, size: size)
        var fronts: [CGRect] = []
        var seen = Set<Int>()

        for window in windows {
            let r = window.frame.offsetBy(dx: -origin.x, dy: -origin.y)
            // A layer-0 window covering a whole display is almost always a transparent utility overlay.
            let coversDisplay = window.frame.contains(screenRect.insetBy(dx: 1, dy: 1))
            defer { if !coversDisplay { fronts.append(r) } }
            // Only windows with room above them for leaves.
            guard window.frame.intersects(screenRect), r.maxY < usableTop - 16, r.maxY > 40 else { continue }
            let lo = max(r.minX + 14, 0), hi = min(r.maxX - 14, size.width)
            guard hi - lo >= 60 else { continue }
            seen.insert(window.id)

            let surface: Surface
            var restored = false
            if let existing = windowSurfaces[window.id] {
                if abs(existing.frame.minX - r.minX) < 0.5 && abs(existing.frame.maxY - r.maxY) < 0.5
                    && abs(existing.frame.width - r.width) < 0.5 {
                    surface = existing
                } else {
                    // Moved or resized: its leaves slide off with the motion.
                    let push = CGVector(dx: (r.minX - existing.frame.minX) / WindowTracker.interval,
                                        dy: (r.maxY - existing.frame.maxY) / WindowTracker.interval)
                    let hadLeaves = existing.count > 0
                    drop(existing, push: push)
                    if hadLeaves { wake() }
                    surface = makeWindowSurface(id: window.id, frame: r, minX: lo, maxX: hi)
                }
            } else if let held = vanished.removeValue(forKey: window.id) {
                if held.surface.frame.equalTo(r) {
                    surface = held.surface
                } else {
                    drop(held.surface, push: .zero)
                    surface = makeWindowSurface(id: window.id, frame: r, minX: lo, maxX: hi)
                }
            } else if let stash = stashed.removeValue(forKey: window.id) {
                if stash.surface.frame.equalTo(r) {
                    surface = stash.surface
                    restored = true
                } else {
                    discard(stash.surface)
                    surface = makeWindowSurface(id: window.id, frame: r, minX: lo, maxX: hi)
                }
            } else {
                surface = makeWindowSurface(id: window.id, frame: r, minX: lo, maxX: hi)
            }
            windowSurfaces[window.id] = surface
            updateVisibility(of: surface, fronts: fronts, force: restored)
        }

        for (id, surface) in windowSurfaces where !seen.contains(id) {
            windowSurfaces[id] = nil
            // Decide a moment later: on a Space switch the windows can vanish before macOS announces it.
            if surface.count > 0 { vanished[id] = (surface, now) }
        }
        var dropped = false
        for (id, held) in vanished where now - held.time > 0.6 {
            vanished[id] = nil
            if abs(spaceChangedAt - held.time) < 1.5 {
                // The window went to another Space with the user; keep its leaves for when it returns.
                for leaf in held.surface.leaves { leaf.node.isHidden = true }
                stashed[id] = (held.surface, now)
            } else {
                // Closed or minimized: its leaves drop.
                drop(held.surface, push: .zero)
                dropped = true
            }
        }
        if dropped { wake() }
        for (id, stash) in stashed where now - stash.time > 900 {
            stashed[id] = nil
            discard(stash.surface)
        }
    }

    private func makeWindowSurface(id: Int, frame: CGRect, minX: CGFloat, maxX: CGFloat) -> Surface {
        Surface(id: id, frame: frame, minX: minX, maxX: maxX, baseY: frame.maxY, colWidth: colWidth,
                maxHeight: 20, spillsAtEnds: true)
    }

    /// Leaves on a ledge that another window now covers hide until it's uncovered.
    private func updateVisibility(of s: Surface, fronts: [CGRect], force: Bool) {
        for c in 0..<s.columns {
            let cx = s.centerX(c)
            let probe = CGRect(x: cx - s.colWidth / 2, y: s.baseY - 2, width: s.colWidth, height: s.maxHeight + 16)
            let visible = !fronts.contains { $0.intersects(probe) }
            if visible != s.visible[c] || force {
                for leaf in s.stacks[c] { leaf.node.isHidden = !visible }
            }
            s.visible[c] = visible
        }
    }

    private func drop(_ s: Surface, push: CGVector) {
        let px = clamp(push.dx, -700, 700), py = clamp(push.dy, -700, 700)
        for c in 0..<s.columns {
            for leaf in s.stacks[c] {
                leaf.surface = nil
                leaf.column = -1
                if !s.visible[c] {
                    remove(leaf)
                    continue
                }
                leaf.vx = px * rnd(0.5, 0.9) + rnd(-25, 25)
                leaf.vy = max(py, 0) * rnd(0.3, 0.6) + rnd(-5, 30)
                launch(leaf, spin: 0.4)
            }
            s.stacks[c].removeAll()
            s.heights[c] = 0
        }
        s.count = 0
    }

    private func discard(_ s: Surface) {
        for leaf in s.leaves {
            leaf.surface = nil
            remove(leaf)
        }
        for c in 0..<s.columns { s.stacks[c].removeAll() }
        s.count = 0
    }

    private func dropAllWindowSurfaces() {
        for surface in windowSurfaces.values { drop(surface, push: .zero) }
        windowSurfaces.removeAll()
        for held in vanished.values { drop(held.surface, push: .zero) }
        vanished.removeAll()
        for stash in stashed.values { discard(stash.surface) }
        stashed.removeAll()
    }

    // MARK: Debugging

    private func debugTick(_ dt: TimeInterval) {
        if let at = debugClearAt, time >= at {
            debugClearAt = nil
            clearAll()
        }
        frames += 1
        statsTimer += dt
        if statsTimer >= 5 {
            let airborne = active.filter { $0.state == .airborne }.count
            FileHandle.standardError.write(String(
                format: "[rustle] t=%.0fs fps=%.0f airborne=%d active=%d ground=%d windows=%d ledges=%d fill=%.2f gusts=%d\n",
                time, Double(frames) / statsTimer, airborne, active.count, ground.count,
                totalResting - ground.count, windowSurfaces.count, pileFill, gusts.count).data(using: .utf8)!)
            frames = 0
            statsTimer = 0
        }
        if let prefix = snapshotPrefix, time >= nextSnapshot, snapshotCount < 40 {
            nextSnapshot = time + 5
            snapshotCount += 1
            writeSnapshot(to: String(format: "%@-%02d.png", prefix, snapshotCount))
        }
    }

    /// Renders the scene over a plain desktop-like backdrop.
    private func writeSnapshot(to path: String) {
        guard let view, let texture = view.texture(from: self, crop: CGRect(origin: .zero, size: size)) else { return }
        let image = texture.cgImage()
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let colors = [CGColor(red: 0.16, green: 0.2, blue: 0.27, alpha: 1), CGColor(red: 0.42, green: 0.46, blue: 0.52, alpha: 1)]
        let gradient = CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        let scale = CGFloat(w) / size.width
        ctx.setFillColor(CGColor(red: 0.93, green: 0.93, blue: 0.95, alpha: 1))
        for s in windowSurfaces.values {
            ctx.fill(CGRect(x: s.frame.minX * scale, y: s.frame.minY * scale,
                            width: s.frame.width * scale, height: s.frame.height * scale))
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, out, nil)
        CGImageDestinationFinalize(dest)
    }
}
