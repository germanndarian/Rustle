import Foundation
import AVFoundation

/// The sounds of the leaf pile: dry leaves crackling under the cursor, a rake dragging leaves,
/// and a soft electric leaf blower.
///
/// Everything is synthesized live in one `AVAudioSourceNode`, nothing is pre-rendered, so nothing
/// ever repeats. Leaves are modelled the way crackling materials behave physically: a stream of tiny
/// fracture clicks, each a few samples of excitation ringing a small random resonator, with a
/// power-law amplitude distribution (many faint ticks, a few crisp snaps) and bursty, self-exciting
/// timing whose rate follows how hard the leaves are being disturbed. There is no clock or grid
/// anywhere, so no putt-putt pulsing.
///
/// Threading: the public methods are called on the main thread and only write a few numbers into a
/// lock-protected mailbox (well under a microsecond). The render thread picks them up with a
/// try-lock, so it never waits. Engine work (build, start, pause) runs on a private serial queue,
/// because it can block for 10-150 ms. The engine starts on the first sound and pauses after
/// a few silent seconds, so the audio hardware sleeps while nobody touches the leaves.
final class CrunchAudio {
    /// When false, `crunch`, `rake` and `blower` are no-ops and the audio engine is stopped.
    var isEnabled: Bool = true {
        didSet {
            guard oldValue != isEnabled else { return }
            let enabled = isEnabled
            if !enabled { controls.silence() }
            audioQueue.async { [weak self] in self?.setEnabled(enabled) }
        }
    }

    private let controls = CrunchControls()
    private var lastWake = -Double.infinity  // main thread

    // Audio queue only.
    private let audioQueue = DispatchQueue(label: "Rustle.CrunchAudio", qos: .userInteractive)
    private var enabled = true
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private var retryAfter: Double = 0
    private var idleCheckPending = false

    init() {
        // Pre-build the graph (no audio I/O yet) so the first sound only pays for start().
        // Delayed a little so an app that turns the sound off at launch never builds it.
        audioQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.enabled, self.engine == nil else { return }
            self.buildEngine()
        }
    }

    deinit {
        if let observer = configObserver { NotificationCenter.default.removeObserver(observer) }
        engine?.stop()
    }

    /// - Parameters:
    ///   - intensity: 0...1. Near 0 is a soft rustle (cursor brushing a few leaves),
    ///     near 1 a crisp, full crunch (cursor ploughing fast through a deep pile).
    ///   - pan: -1 (left) ... 1 (right), where on screen it happened.
    func crunch(intensity: Float, pan: Float) {
        guard isEnabled else { return }
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.crunch(intensity: intensity, pan: pan) }
            return
        }
        let level = Self.unitValue(intensity)
        guard level > 0.005 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        controls.crunch(level, pan: Self.panValue(pan), at: now)
        wake(now)
    }

    /// A rake dragging leaves. Call every frame while the rake moves leaves.
    /// - Parameters:
    ///   - intensity: 0...1, roughly how many leaves are being dragged times how fast. 0 (or no
    ///     calls) when the rake isn't moving leaves; the sound then settles within ~150 ms.
    ///   - pan: -1 (left) ... 1 (right).
    func rake(intensity: Float, pan: Float) {
        guard isEnabled else { return }
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.rake(intensity: intensity, pan: pan) }
            return
        }
        let level = Self.unitValue(intensity)
        guard level > 0.005 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        controls.rake(level, pan: Self.panValue(pan), at: now)
        wake(now)
    }

    /// A handheld electric leaf blower. Call every frame while the blower is equipped.
    /// - Parameters:
    ///   - level: 1 while the trigger is held, 0 when released (values in between work too).
    ///     It spins up over ~0.3 s and down over ~0.7 s.
    ///   - pan: -1 (left) ... 1 (right).
    func blower(level: Float, pan: Float) {
        guard isEnabled else { return }
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.blower(level: level, pan: pan) }
            return
        }
        let value = Self.unitValue(level)
        let now = ProcessInfo.processInfo.systemUptime
        controls.blower(value, pan: Self.panValue(pan), at: now)
        if value > 0 { wake(now) }
    }

    private static func unitValue(_ x: Float) -> Float { x.isFinite ? min(max(x, 0), 1) : 0 }
    private static func panValue(_ x: Float) -> Float { x.isFinite ? min(max(x, -1), 1) : 0 }

    /// Asks the audio queue to make sure the engine runs (at most every 0.1 s while sound is wanted).
    private func wake(_ now: Double) {
        guard now - lastWake > CrunchTuning.wakeInterval else { return }
        lastWake = now
        audioQueue.async { [weak self] in self?.ensureRunning() }
    }

    // MARK: Audio queue

    private func setEnabled(_ value: Bool) {
        enabled = value
        if !value {
            tearDownEngine()
        } else if engine == nil {
            buildEngine()
        }
    }

    /// Builds (if needed) and starts the engine. Fails silently, with a back-off, when there is no usable output.
    private func ensureRunning() {
        guard enabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if engine?.isRunning != true {
            guard now >= retryAfter else { return }
            if engine == nil { buildEngine() }
            guard let engine = engine else {
                retryAfter = now + CrunchTuning.retryDelay
                return
            }
            do {
                try engine.start()
            } catch {
                tearDownEngine()
                retryAfter = now + CrunchTuning.retryDelay
                return
            }
        }
        scheduleIdleCheck(after: CrunchTuning.idleTimeout + CrunchTuning.tail)
    }

    private func buildEngine() {
        let engine = AVAudioEngine()
        // Never touch inputNode (that would ask for the microphone). Check the output first:
        // connecting to an output with no channels / no sample rate raises an exception.
        let output = engine.outputNode.outputFormat(forBus: 0)
        guard output.sampleRate > 0, output.channelCount > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: output.sampleRate, channels: 2) else { return }
        // Synthesize at the device rate, so the mixer has nothing to resample.
        let dsp = CrunchDSP(sampleRate: output.sampleRate, controls: controls, seed: UInt64.random(in: 1...UInt64.max))
        let source = AVAudioSourceNode(format: format) { isSilence, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
                for buffer in buffers where buffer.mData != nil { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
                isSilence.pointee = true
                return noErr
            }
            if !dsp.render(frames: Int(frameCount), left: left, right: right) { isSilence.pointee = true }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1
        engine.prepare()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self, weak engine] _ in
            // Output device or format changed (headphones, AirPlay, sample rate...). The engine has
            // stopped itself; replace it with one built against the new device.
            self?.audioQueue.async { [weak self] in
                guard let self = self, let changed = engine, changed === self.engine else { return }
                self.tearDownEngine()
                self.retryAfter = 0
                if self.enabled { self.buildEngine() }
            }
        }
        self.engine = engine
    }

    private func tearDownEngine() {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        engine?.stop()
        engine = nil
    }

    /// Pauses the engine (stopping the audio hardware) once nothing has been asked for in a while.
    private func scheduleIdleCheck(after delay: Double) {
        guard !idleCheckPending else { return }
        idleCheckPending = true
        audioQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.idleCheckPending = false
            guard let engine = self.engine, engine.isRunning else { return }
            let quiet = ProcessInfo.processInfo.systemUptime - self.controls.lastActivityTime()
            let remaining = CrunchTuning.idleTimeout + CrunchTuning.tail - quiet
            if remaining > 0.05 {
                self.scheduleIdleCheck(after: remaining)
            } else {
                engine.pause()  // keeps the graph; resuming costs ~45 ms
            }
        }
    }
}

// MARK: - Offline rendering (used by the test harness, not by the app)

extension CrunchAudio {
    enum TestCall {
        case crunch(Float, Float)
        case rake(Float, Float)
        case blower(Float, Float)
    }

    /// Renders `seconds` of audio through the same DSP the app uses. `calls(frame)` is asked for the
    /// calls of each 60 Hz frame; they reach the DSP at the next `blockSize` boundary, like in the app.
    static func renderForTesting(seconds: Double, sampleRate: Double = 48_000, blockSize: Int = 512, seed: UInt64 = 1,
                                 calls: (Int) -> [TestCall]) -> (left: [Float], right: [Float]) {
        let controls = CrunchControls()
        let dsp = CrunchDSP(sampleRate: sampleRate, controls: controls, seed: seed)
        let total = Int(seconds * sampleRate)
        var left = [Float](repeating: 0, count: total)
        var right = [Float](repeating: 0, count: total)
        var frame = 0
        var position = 0
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                while position < total {
                    while Double(frame) / 60 <= Double(position) / sampleRate {
                        let t = Double(frame) / 60
                        for call in calls(frame) {
                            switch call {
                            case let .crunch(i, p): if i > 0.005 { controls.crunch(min(max(i, 0), 1), pan: p, at: t) }
                            case let .rake(i, p): if i > 0.005 { controls.rake(min(max(i, 0), 1), pan: p, at: t) }
                            case let .blower(v, p): controls.blower(min(max(v, 0), 1), pan: p, at: t)
                            }
                        }
                        frame += 1
                    }
                    let n = min(blockSize, total - position)
                    _ = dsp.render(frames: n, left: l.baseAddress! + position, right: r.baseAddress! + position)
                    position += n
                }
            }
        }
        return (left, right)
    }

    var isEngineRunningForTesting: Bool { audioQueue.sync { engine?.isRunning ?? false } }
    var hasEngineForTesting: Bool { audioQueue.sync { engine != nil } }

    /// Posts the configuration-change notification for the current engine, as an output-device switch would.
    func simulateConfigurationChangeForTesting() {
        guard let engine = audioQueue.sync(execute: { self.engine }) else { return }
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
    }
}

// MARK: - Tuning

fileprivate enum CrunchTuning {
    static let idleTimeout: Double = 3.0
    /// Blower spin-down and crackle settling after the last request.
    static let tail: Double = 1.0
    static let retryDelay: Double = 2.0
    static let wakeInterval: Double = 0.1
}

// MARK: - Main thread -> render thread mailbox

/// A few numbers guarded by an unfair lock. The main thread holds it for a handful of stores;
/// the render thread only ever try-locks it, so it never blocks.
fileprivate final class CrunchControls {
    private let lock: UnsafeMutablePointer<os_unfair_lock>

    var crunchPending = false
    var crunchMax: Float = 0
    var crunchPanSum: Float = 0
    var crunchWeight: Float = 0
    var rakePending = false
    var rakeMax: Float = 0
    var rakePanSum: Float = 0
    var rakeWeight: Float = 0
    var blowerLevel: Float = 0
    var blowerPan: Float = 0
    private var activity = -Double.infinity

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    func tryLock() -> Bool { os_unfair_lock_trylock(lock) }
    func unlock() { os_unfair_lock_unlock(lock) }

    func crunch(_ level: Float, pan: Float, at time: Double) {
        os_unfair_lock_lock(lock)
        crunchPending = true
        crunchMax = max(crunchMax, level)
        crunchPanSum += pan * level
        crunchWeight += level
        activity = time
        os_unfair_lock_unlock(lock)
    }

    func rake(_ level: Float, pan: Float, at time: Double) {
        os_unfair_lock_lock(lock)
        rakePending = true
        rakeMax = max(rakeMax, level)
        rakePanSum += pan * level
        rakeWeight += level
        activity = time
        os_unfair_lock_unlock(lock)
    }

    func blower(_ level: Float, pan: Float, at time: Double) {
        os_unfair_lock_lock(lock)
        blowerLevel = level
        blowerPan = pan
        if level > 0 { activity = time }
        os_unfair_lock_unlock(lock)
    }

    func silence() {
        os_unfair_lock_lock(lock)
        crunchPending = false
        crunchMax = 0; crunchPanSum = 0; crunchWeight = 0
        rakePending = false
        rakeMax = 0; rakePanSum = 0; rakeWeight = 0
        blowerLevel = 0
        os_unfair_lock_unlock(lock)
    }

    func lastActivityTime() -> Double {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return activity
    }
}

// MARK: - Synthesis (render thread)

/// All the sound, rendered block by block on the audio render thread. No allocation, no locks
/// (beyond a try-lock), no Swift arrays in the render path.
fileprivate final class CrunchDSP {
    private static let chunk = 256
    private static let voiceCount = 96
    private static let stride = 16  // floats of state per click voice

    private let sr: Float
    private let invSr: Float
    private let controls: CrunchControls
    private let rng: UnsafeMutablePointer<CrunchNoise>

    // Click voices (struct of arrays). A voice is a short excitation ringing one or two resonant
    // modes. Float state layout per voice: 0 excitation gain, 1-2 excitation history,
    // 3-4 mode-1 state, 5-7 mode-1 coefficients (a1, a2, b0), 8-9 mode-2 state,
    // 10-12 mode-2 coefficients, 13-14 left/right gain.
    private let life: UnsafeMutablePointer<Int32>
    private let start: UnsafeMutablePointer<Int32>
    private let excitation: UnsafeMutablePointer<Int32>
    private let state: UnsafeMutablePointer<Float>
    private var nextVoice = 0
    private var liveVoices = 0

    // Per-sample smoothing factors (1 - exp(-1 / (tau * sr))).
    private let kCrunchAttack: Float, kCrunchHeld: Float, kCrunchRelease: Float
    private let kRakeAttack: Float, kRakeHeld: Float, kRakeRelease: Float
    private let kSpinUp: Float, kSpinDown: Float
    private let kCompDetect: Float, kCompAttack: Float, kCompRelease: Float
    private let crunchHold: Int, rakeHold: Int
    private let crunchHawkesDecay: Float, rakeHawkesDecay: Float
    // Per-chunk Ornstein-Uhlenbeck factors (exp(-chunk / tau)).
    private let ou40: Float, ou60: Float, ou90: Float, ou150: Float, ou300: Float, ou35: Float

    // Crunch: smoothed intensity envelope, Hawkes excitation (events/s), slow rate modulation.
    private var cEnv: Float = 0, cTarget: Float = 0, cHoldLeft = 0, cPan: Float = 0
    private var cHawkes: Float = 0, cWave: Float = 0, cWave2: Float = 0
    private var kickAt = -1

    // Rake.
    private var rEnv: Float = 0, rTarget: Float = 0, rHoldLeft = 0, rPan: Float = 0, rPanSmooth: Float = 0
    private var rHawkes: Float = 0, rWave: Float = 0, rSwishWave: Float = 0, rSwishTone: Float = 0
    private var swishGain: Float = 0
    private var swishBandL = CrunchSVF(), swishBandR = CrunchSVF(), swishHighL = CrunchSVF(), swishHighR = CrunchSVF()
    private let tineTimer: UnsafeMutablePointer<Float>  // samples until each tine's next scrape tick
    private let tineWave: UnsafeMutablePointer<Float>
    private let tineGate: UnsafeMutablePointer<Float>

    // Blower.
    private var bTarget: Float = 0, bSpinA: Float = 0, bSpin: Float = 0, bPan: Float = 0, bPanSmooth: Float = 0
    private var bPhase: Float = 0, bSlow: Float = 0, bFast: Float = 0, bWobble: Float = 0, bFlutter: Float = 1
    private var pinkL = (Float(0), Float(0), Float(0)), pinkR = (Float(0), Float(0), Float(0))
    private var airHighL = CrunchSVF(), airHighR = CrunchSVF(), airLowL = CrunchSVF(), airLowR = CrunchSVF()
    private var airBodyL = CrunchSVF(), airBodyR = CrunchSVF()

    // Master safety: slow loudness compressor, then a soft clipper on the rare peak.
    private var compPower: Float = 0, compGain: Float = 1

    init(sampleRate: Double, controls: CrunchControls, seed: UInt64) {
        sr = Float(sampleRate)
        invSr = 1 / sr
        self.controls = controls
        rng = .allocate(capacity: 1)
        rng.initialize(to: CrunchNoise(seed: seed))
        let n = Self.voiceCount
        life = .allocate(capacity: n); life.initialize(repeating: 0, count: n)
        start = .allocate(capacity: n); start.initialize(repeating: 0, count: n)
        excitation = .allocate(capacity: n); excitation.initialize(repeating: 0, count: n)
        state = .allocate(capacity: n * Self.stride); state.initialize(repeating: 0, count: n * Self.stride)
        tineTimer = .allocate(capacity: 3); tineTimer.initialize(repeating: 0, count: 3)
        tineWave = .allocate(capacity: 3); tineWave.initialize(repeating: 0, count: 3)
        tineGate = .allocate(capacity: 3); tineGate.initialize(repeating: 0, count: 3)

        let rate = sr
        func k(_ tau: Float) -> Float { 1 - exp(-1 / (tau * rate)) }
        func ou(_ tau: Float) -> Float { exp(-Float(Self.chunk) / (tau * rate)) }
        kCrunchAttack = k(0.004); kCrunchHeld = k(0.04); kCrunchRelease = k(0.055)
        kRakeAttack = k(0.03); kRakeHeld = k(0.05); kRakeRelease = k(0.07)
        kSpinUp = k(0.063); kSpinDown = k(0.148)  // two cascaded stages: ~0.3 s up, ~0.7 s down
        kCompDetect = k(0.05); kCompAttack = k(0.01); kCompRelease = k(0.3)
        crunchHold = Int(0.07 * rate); rakeHold = Int(0.08 * rate)
        crunchHawkesDecay = exp(-1 / (0.007 * rate)); rakeHawkesDecay = exp(-1 / (0.006 * rate))
        ou40 = ou(0.04); ou60 = ou(0.06); ou90 = ou(0.09); ou150 = ou(0.15); ou300 = ou(0.3); ou35 = ou(0.035)
    }

    deinit {
        rng.deinitialize(count: 1); rng.deallocate()
        life.deallocate(); start.deallocate(); excitation.deallocate(); state.deallocate()
        tineTimer.deallocate(); tineWave.deallocate(); tineGate.deallocate()
    }

    /// Renders `frames` stereo samples. Returns false when the output is pure silence.
    func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) -> Bool {
        consumeControls()
        var audible = false
        var offset = 0
        while offset < frames {
            let n = min(Self.chunk, frames - offset)
            if renderChunk(n, left + offset, right + offset) { audible = true }
            offset += n
        }
        return audible
    }

    private func consumeControls() {
        guard controls.tryLock() else { return }  // main thread is mid-write: pick it up next block
        var crunch: (Float, Float)? = nil, rake: (Float, Float)? = nil
        if controls.crunchPending {
            crunch = (controls.crunchMax, controls.crunchPanSum / max(controls.crunchWeight, 1e-6))
            controls.crunchPending = false
            controls.crunchMax = 0; controls.crunchPanSum = 0; controls.crunchWeight = 0
        }
        if controls.rakePending {
            rake = (controls.rakeMax, controls.rakePanSum / max(controls.rakeWeight, 1e-6))
            controls.rakePending = false
            controls.rakeMax = 0; controls.rakePanSum = 0; controls.rakeWeight = 0
        }
        bTarget = controls.blowerLevel
        bPan = controls.blowerPan
        controls.unlock()

        if let (level, pan) = crunch {
            // A sudden rise (a fresh kick) sets off an immediate cluster of snaps.
            let rise = level - cEnv
            if rise > 0.06 {
                cHawkes += 900 * rise
                kickAt = Int(rng.pointee.unit() * 48)
            }
            cTarget = level
            cHoldLeft = crunchHold
            cPan = pan
        }
        if let (level, pan) = rake {
            rTarget = level
            rHoldLeft = rakeHold
            rPan = pan
        }
    }

    private func renderChunk(_ n: Int, _ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>) -> Bool {
        left.update(repeating: 0, count: n)
        right.update(repeating: 0, count: n)
        let crackleIdle = cEnv < 1e-4 && cHoldLeft == 0 && cHawkes < 0.5 && kickAt < 0
            && rEnv < 1e-4 && rHoldLeft == 0 && rHawkes < 0.5 && liveVoices == 0
        let blowerIdle = bSpin < 1e-5 && bSpinA < 1e-5 && bTarget == 0
        if crackleIdle && blowerIdle {
            compGain = 1
            compPower = 0
            return false
        }
        if !crackleIdle {
            let rakeEnvBefore = rEnv
            spawnEvents(n)
            renderVoices(n, left, right)
            renderSwish(n, left, right, from: rakeEnvBefore, to: rEnv)
        }
        if !blowerIdle { renderBlower(n, left, right) }
        master(n, left, right)
        return true
    }

    // MARK: Events

    @inline(__always) private func ou(_ z: inout Float, _ a: Float) {
        z = z * a + (1 - a * a).squareRoot() * rng.pointee.gauss()
    }

    /// Walks the chunk sample by sample, updating the envelopes and drawing fracture events.
    private func spawnEvents(_ n: Int) {
        ou(&cWave, ou60); ou(&cWave2, ou90); ou(&rWave, ou90)
        ou(&rSwishWave, ou60); ou(&rSwishTone, ou150)
        for t in 0..<3 {
            ou(&tineWave[t], ou150)
            ou(&tineGate[t], ou90)
        }
        // Slow, aperiodic "waves" in the crumpling rate (doubly stochastic Poisson process).
        let snapRate = 900 * exp(0.55 * cWave - 0.15)
        let crinkleRate = 2200 * exp(0.45 * cWave2 - 0.1)
        let rakeCrinkleRate = 3600 * exp(0.5 * rWave - 0.125)
        let rakeSnapRate = 110 * exp(0.5 * rWave - 0.125)
        let crunchStep: Float = 0.55 / 0.007  // Hawkes branching ratio 0.55 over a 7 ms kernel
        let rakeStep: Float = 0.35 / 0.006

        var envC = cEnv, targetC = cTarget, holdC = cHoldLeft, hawkesC = cHawkes
        var envR = rEnv, targetR = rTarget, holdR = rHoldLeft, hawkesR = rHawkes
        let r = rng
        for i in 0..<n {
            // Crunch envelope: fast attack, held while calls keep coming, then a natural settle.
            if holdC > 0 {
                holdC -= 1
                envC += (targetC - envC) * (targetC > envC ? kCrunchAttack : kCrunchHeld)
            } else {
                targetC = 0
                envC -= envC * kCrunchRelease
            }
            if i == kickAt {
                spawnCrunchSnap(i, env: max(envC, targetC), kick: true)
                kickAt = -1
            }
            if envC > 1e-4 || hawkesC > 0.5 {
                let lambda = snapRate * envC * pow(envC, 0.2) + hawkesC
                if r.pointee.unit() < lambda * invSr {
                    spawnCrunchSnap(i, env: envC, kick: false)
                    hawkesC += crunchStep
                }
                if r.pointee.unit() < crinkleRate * envC * invSr { spawnCrunchCrinkle(i, env: envC) }
            }
            hawkesC *= crunchHawkesDecay

            // Rake envelope.
            if holdR > 0 {
                holdR -= 1
                envR += (targetR - envR) * (targetR > envR ? kRakeAttack : kRakeHeld)
            } else {
                targetR = 0
                envR -= envR * kRakeRelease
            }
            if envR > 1e-4 || hawkesR > 0.5 {
                if r.pointee.unit() < rakeCrinkleRate * envR * invSr { spawnRakeCrinkle(i, env: envR) }
                if r.pointee.unit() < (rakeSnapRate * envR * envR + hawkesR) * invSr {
                    spawnRakeSnap(i, env: envR)
                    hawkesR += rakeStep
                }
                if envR > 0.01 {
                    for t in 0..<3 {
                        tineTimer[t] -= 1
                        if tineTimer[t] <= 0 { scrape(t, at: i, env: envR) }
                    }
                }
            }
            hawkesR *= rakeHawkesDecay
        }
        if kickAt >= 0 { kickAt = -1 }
        cEnv = envC; cTarget = targetC; cHoldLeft = holdC; cHawkes = hawkesC
        rEnv = envR; rTarget = targetR; rHoldLeft = holdR; rHawkes = hawkesR
    }

    /// Clipped Pareto (power-law) amplitude in (0, 1]: mostly faint, now and then a loud one.
    @inline(__always) private func powerLaw(alpha: Float, range: Float) -> Float {
        min(range, pow(max(rng.pointee.unit(), 1e-7), -1 / alpha)) / range
    }

    private func spawnCrunchSnap(_ at: Int, env: Float, kick: Bool) {
        let r = rng
        var x = powerLaw(alpha: 2.1, range: 10)
        if kick { x = max(x, r.pointee.uniform(0.3, 0.9)) }  // a fresh kick starts with a crisp snap
        let loudness = 0.45 + 0.55 * env.squareRoot()
        let f: Float, q: Float, ratio: Float, second: Float
        if x > 0.45 && r.pointee.unit() < 0.2 {
            // A big fragment breaking: lower and rounder (this is all the "body" there is).
            f = r.pointee.logUniform(800, 1600); q = r.pointee.logUniform(1.8, 3.5)
            ratio = r.pointee.uniform(1.9, 2.8); second = r.pointee.uniform(0.35, 0.7)
        } else {
            f = r.pointee.logUniform(1400, 9000); q = r.pointee.logUniform(2.5, 9)
            ratio = r.pointee.uniform(1.45, 2.7); second = r.pointee.uniform(0.15, 0.55)
        }
        let amp = x * loudness * pow(f / 3000, -0.2) * 1.05
        voice(at, amp: amp, f, q: q, f * ratio, q2: q * r.pointee.uniform(0.6, 1), second: second,
              excitation: 1 + Int(r.pointee.unit() * 3), pan: cPan + 0.22 * r.pointee.gauss())
    }

    private func spawnCrunchCrinkle(_ at: Int, env: Float) {
        let r = rng
        let amp = powerLaw(alpha: 2.4, range: 8) * (0.45 + 0.55 * env.squareRoot()) * 0.5
        voice(at, amp: amp, r.pointee.logUniform(2500, 9000), q: r.pointee.logUniform(1.5, 5), 0, q2: 1, second: 0,
              excitation: 1 + Int(r.pointee.unit() * 2), pan: cPan + 0.3 * r.pointee.gauss())
    }

    private func spawnRakeCrinkle(_ at: Int, env: Float) {
        let r = rng
        let amp = powerLaw(alpha: 2.6, range: 10) * (0.3 + 0.7 * env) * 1.0
        voice(at, amp: amp, r.pointee.logUniform(1200, 6500), q: r.pointee.logUniform(1.4, 4.5), 0, q2: 1, second: 0,
              excitation: 1 + Int(r.pointee.unit() * 2), pan: rPan + 0.3 * r.pointee.gauss())
    }

    private func spawnRakeSnap(_ at: Int, env: Float) {
        let r = rng
        let f = r.pointee.logUniform(1200, 6000)
        let amp = powerLaw(alpha: 1.8, range: 14) * (0.3 + 0.7 * env) * 1.7 * pow(f / 3000, -0.2)
        voice(at, amp: amp, f, q: r.pointee.logUniform(2.5, 7), f * r.pointee.uniform(1.5, 2.6), q2: 3,
              second: r.pointee.uniform(0.15, 0.5), excitation: 1 + Int(r.pointee.unit() * 3),
              pan: rPan + 0.25 * r.pointee.gauss())
    }

    /// One tine catching on the ground: a thin dry tick. Gamma(3)-distributed gaps give a scratchy,
    /// irregular scrape rather than a pitched buzz.
    private func scrape(_ t: Int, at: Int, env: Float) {
        let r = rng
        let rate = (70 + 300 * env) * exp(0.35 * tineWave[t])
        let gap = -log(max(r.pointee.unit(), 1e-7) * max(r.pointee.unit(), 1e-7) * max(r.pointee.unit(), 1e-7)) / (3 * rate)
        tineTimer[t] = gap * sr
        let gate = min(max(0.55 + 0.6 * tineGate[t], 0), 1)
        let amp = env * gate * (0.35 + 0.65 * r.pointee.unit()) * 0.6
        voice(at, amp: amp, r.pointee.logUniform(2500, 6500), q: r.pointee.logUniform(2, 3.5), 0, q2: 1, second: 0,
              excitation: 1, pan: rPan + (Float(t) - 1) * 0.12 + 0.05 * r.pointee.gauss())
    }

    private func voice(_ at: Int, amp: Float, _ f1: Float, q q1: Float, _ f2: Float, q2: Float, second: Float,
                       excitation exc: Int, pan: Float) {
        guard amp > 1e-5 else { return }
        var slot = -1
        for k in 0..<Self.voiceCount {
            let v = (nextVoice + k) % Self.voiceCount
            if life[v] == 0 { slot = v; break }
        }
        guard slot >= 0 else { return }  // all busy: a dropped tick is inaudible
        nextVoice = (slot + 1) % Self.voiceCount
        let p = state + slot * Self.stride
        let top = 0.45 * sr
        let fa = min(f1, top)
        let r1 = exp(-Float.pi * fa / (q1 * sr)), w1 = 2 * Float.pi * fa / sr
        p[5] = -2 * r1 * cos(w1); p[6] = r1 * r1
        p[7] = amp * (1 - r1).squareRoot()  // equal energy whatever the pitch and ring time
        var ring = 6.9 * q1 * sr / (Float.pi * fa)
        if second > 0 && f2 < top {
            let r2 = exp(-Float.pi * f2 / (q2 * sr)), w2 = 2 * Float.pi * f2 / sr
            p[10] = -2 * r2 * cos(w2); p[11] = r2 * r2
            p[12] = amp * second * (1 - r2).squareRoot()
            ring = max(ring, 6.9 * q2 * sr / (Float.pi * f2))
        } else {
            p[10] = 0; p[11] = 0; p[12] = 0
        }
        p[0] = 1 / Float(exc).squareRoot()
        p[1] = 0; p[2] = 0; p[3] = 0; p[4] = 0; p[8] = 0; p[9] = 0
        let theta = (min(max(pan, -1), 1) + 1) * Float.pi / 4
        p[13] = cos(theta); p[14] = sin(theta)
        life[slot] = Int32(min(ring, 0.05 * sr)) + Int32(exc) + 3
        start[slot] = Int32(at)
        excitation[slot] = Int32(exc)
        liveVoices += 1
    }

    private func renderVoices(_ n: Int, _ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>) {
        var live = 0
        let r = rng
        for v in 0..<Self.voiceCount where life[v] > 0 {
            let p = state + v * Self.stride
            var x1 = p[1], x2 = p[2], y1 = p[3], y2 = p[4], z1 = p[8], z2 = p[9]
            let gain = p[0], a1 = p[5], a2 = p[6], b0 = p[7], c1 = p[10], c2 = p[11], d0 = p[12]
            let gl = p[13], gr = p[14]
            var exc = Int(excitation[v])
            let first = Int(start[v])
            let remaining = Int(life[v])
            let stop = min(n, first + remaining)
            var i = first
            if d0 == 0 {
                while i < stop {
                    var x: Float = 0
                    if exc > 0 { x = gain * r.pointee.bipolar(); exc -= 1 }
                    let d = x - x2; x2 = x1; x1 = x
                    let y = b0 * d - a1 * y1 - a2 * y2; y2 = y1; y1 = y
                    left[i] += y * gl; right[i] += y * gr
                    i += 1
                }
            } else {
                while i < stop {
                    var x: Float = 0
                    if exc > 0 { x = gain * r.pointee.bipolar(); exc -= 1 }
                    let d = x - x2; x2 = x1; x1 = x
                    let y = b0 * d - a1 * y1 - a2 * y2; y2 = y1; y1 = y
                    let z = d0 * d - c1 * z1 - c2 * z2; z2 = z1; z1 = z
                    let s = y + z
                    left[i] += s * gl; right[i] += s * gr
                    i += 1
                }
            }
            p[1] = x1; p[2] = x2; p[3] = y1; p[4] = y2; p[8] = z1; p[9] = z2
            excitation[v] = Int32(exc)
            start[v] = 0
            let left = remaining - (stop - first)
            life[v] = Int32(max(0, left))
            if left > 0 { live += 1 }
        }
        liveVoices = live
    }

    /// The rake's "shhk": leaves sliding over each other, a slowly wandering band of air-like noise.
    private func renderSwish(_ n: Int, _ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>,
                             from envStart: Float, to envEnd: Float) {
        if envStart < 1e-4 && envEnd < 1e-4 && swishGain < 1e-5 { swishGain = 0; return }
        let centre = min(max(1900 * exp(0.35 * rSwishTone), 1200), 4000)
        swishBandL.set(centre, q: 0.75, sampleRate: sr); swishBandR.set(centre * 1.07, q: 0.75, sampleRate: sr)
        swishHighL.set(700, q: 0.7, sampleRate: sr); swishHighR.set(700, q: 0.7, sampleRate: sr)
        let motion = min(max(0.55 + 0.4 * rSwishWave, 0.1), 1.2)
        let target = 0.36 * envEnd * envEnd.squareRoot() * motion
        rPanSmooth += (rPan - rPanSmooth) * 0.2
        let theta = (rPanSmooth + 1) * Float.pi / 4
        let gl = cos(theta), gr = sin(theta)
        var g = swishGain
        let step = (target - g) / Float(n)
        var bandL = swishBandL, bandR = swishBandR, highL = swishHighL, highR = swishHighR
        let r = rng
        for i in 0..<n {
            g += step
            let a = r.pointee.bipolar(), b = r.pointee.bipolar()
            let l = highL.process(bandL.process(a).band).high
            let rr = highR.process(bandR.process(0.55 * a + 0.835 * b).band).high
            left[i] += l * g * gl
            right[i] += rr * g * gr
        }
        swishBandL = bandL; swishBandR = bandR; swishHighL = highL; swishHighR = highR
        swishGain = g
    }

    // MARK: Blower

    private func renderBlower(_ n: Int, _ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>) {
        // Turbulence: two slow random processes (no LFO, so no periodic wobble).
        ou(&bSlow, ou300); ou(&bFast, ou35); ou(&bWobble, ou150)
        let flutterTarget = max(0.2, 1 + 0.2 * bSlow + 0.09 * bFast)
        let spinNow = bSpin
        let cutoff = (1300 + 2900 * spinNow) * (1 + 0.1 * bSlow)
        airHighL.set(300, q: 0.7, sampleRate: sr); airHighR.set(300, q: 0.7, sampleRate: sr)
        airLowL.set(cutoff, q: 0.55, sampleRate: sr); airLowR.set(cutoff * 1.05, q: 0.55, sampleRate: sr)
        let body = 700 + 450 * spinNow
        airBodyL.set(body, q: 1.1, sampleRate: sr); airBodyR.set(body * 1.04, q: 1.1, sampleRate: sr)
        bPanSmooth += (bPan - bPanSmooth) * 0.15
        let theta = (bPanSmooth + 1) * Float.pi / 4
        let gl = cos(theta), gr = sin(theta)
        var flutter = bFlutter
        let flutterStep = (flutterTarget - flutter) / Float(n)
        var spinA = bSpinA, spin = bSpin, phase = bPhase
        var pl = pinkL, pr = pinkR
        var highL = airHighL, highR = airHighR, lowL = airLowL, lowR = airLowR, bodyL = airBodyL, bodyR = airBodyR
        let wobble = 1 + 0.003 * bWobble
        let target = bTarget
        let r = rng
        let twoPi = 2 * Float.pi
        for i in 0..<n {
            // Two cascaded one-poles: an S-shaped spin-up/down that can never click.
            let k = target > spinA ? kSpinUp : kSpinDown
            spinA += (target - spinA) * k
            spin += (spinA - spin) * k
            flutter += flutterStep
            let air = spin * spin.squareRoot() * flutter * 0.13
            // Pink-ish air noise (Kellet's economy filter), band-limited to ~300-4000 Hz.
            let wa = r.pointee.bipolar(), wb = r.pointee.bipolar()
            let wl = wa, wr = 0.5 * wa + 0.866 * wb
            pl.0 = 0.99765 * pl.0 + wl * 0.099046; pl.1 = 0.963 * pl.1 + wl * 0.2965164; pl.2 = 0.57 * pl.2 + wl * 1.0526913
            pr.0 = 0.99765 * pr.0 + wr * 0.099046; pr.1 = 0.963 * pr.1 + wr * 0.2965164; pr.2 = 0.57 * pr.2 + wr * 1.0526913
            let nl = (pl.0 + pl.1 + pl.2 + wl * 0.1848) * 0.2
            let nr = (pr.0 + pr.1 + pr.2 + wr * 0.1848) * 0.2
            let al = lowL.process(highL.process(nl).high).low
            let ar = lowR.process(highR.process(nr).high).low
            let sl = al + 0.8 * bodyL.process(al).band
            let sr2 = ar + 0.8 * bodyR.process(ar).band
            // Faint motor whine, rising a little with the spin.
            phase += twoPi * (480 + 340 * spin) * wobble * invSr
            if phase > twoPi { phase -= twoPi }
            let s = sin(phase), c = cos(phase)
            let whine = (s + 0.3 * 2 * s * c + 0.12 * s * (3 - 4 * s * s)) * spin * spin * 0.0045
            left[i] += (sl * air + whine) * gl
            right[i] += (sr2 * air + whine) * gr
        }
        bFlutter = flutter; bSpinA = spinA; bSpin = spin; bPhase = phase
        pinkL = pl; pinkR = pr
        airHighL = highL; airHighR = highR; airLowL = lowL; airLowR = lowR; airBodyL = bodyL; airBodyR = bodyR
        if spin < 1e-5 && spinA < 1e-5 && target == 0 {
            bSpin = 0; bSpinA = 0
            pinkL = (0, 0, 0); pinkR = (0, 0, 0)
        }
    }

    // MARK: Master

    private func master(_ n: Int, _ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>) {
        let threshold: Float = 0.09 * 0.09  // -21 dBFS RMS; only all three sounds at full get near it
        var power = compPower, gain = compGain
        for i in 0..<n {
            var l = left[i], r = right[i]
            power += ((l * l + r * r) * 0.5 - power) * kCompDetect
            let wanted: Float = power > threshold ? pow(threshold / power, 1 / 3) : 1
            gain += (wanted - gain) * (wanted < gain ? kCompAttack : kCompRelease)
            l *= gain; r *= gain
            left[i] = CrunchDSP.softClip(l)
            right[i] = CrunchDSP.softClip(r)
        }
        compPower = power; compGain = gain
    }

    /// Linear up to -7.5 dBFS, then a tanh knee that never exceeds -3 dBFS.
    @inline(__always) private static func softClip(_ x: Float) -> Float {
        let knee: Float = 0.42, ceiling: Float = 0.7
        let a = abs(x)
        if a <= knee { return x }
        let y = knee + (ceiling - knee) * tanh((a - knee) / (ceiling - knee))
        return x < 0 ? -y : y
    }
}

/// Topology-preserving state-variable filter (stable under modulation).
fileprivate struct CrunchSVF {
    private var ic1: Float = 0, ic2: Float = 0
    private var a1: Float = 1, a2: Float = 0, a3: Float = 0, k: Float = 1.4

    mutating func set(_ fc: Float, q: Float, sampleRate: Float) {
        let g = tan(Float.pi * min(fc, 0.45 * sampleRate) / sampleRate)
        k = 1 / q
        a1 = 1 / (1 + g * (g + k))
        a2 = g * a1
        a3 = g * a2
    }

    @inline(__always) mutating func process(_ v0: Float) -> (low: Float, band: Float, high: Float) {
        let v3 = v0 - ic2
        let v1 = a1 * ic1 + a2 * v3
        let v2 = ic2 + a2 * ic1 + a3 * v3
        ic1 = 2 * v1 - ic1
        ic2 = 2 * v2 - ic2
        return (v2, v1, v0 - k * v1 - v2)
    }
}

/// xorshift64*: fast, allocation-free noise for the render thread.
fileprivate struct CrunchNoise {
    private var s: UInt64

    init(seed: UInt64) { s = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

    @inline(__always) mutating func next() -> UInt64 {
        s ^= s >> 12; s ^= s << 25; s ^= s >> 27
        return s &* 0x2545_F491_4F6C_DD1D
    }

    /// Uniform in [0, 1).
    @inline(__always) mutating func unit() -> Float { Float(next() >> 40) * (1 / 16_777_216) }
    /// Uniform in [-1, 1).
    @inline(__always) mutating func bipolar() -> Float {
        Float(Int32(truncatingIfNeeded: next() >> 32)) * (1 / 2_147_483_648)
    }
    @inline(__always) mutating func uniform(_ a: Float, _ b: Float) -> Float { a + (b - a) * unit() }
    @inline(__always) mutating func logUniform(_ a: Float, _ b: Float) -> Float { a * exp(unit() * log(b / a)) }
    /// Roughly Gaussian, unit variance (sum of four uniforms).
    @inline(__always) mutating func gauss() -> Float { (unit() + unit() + unit() + unit() - 2) * 1.732_050_8 }
}
