import Foundation
import AVFoundation

/// Plays the sound of dry leaves being disturbed by the cursor.
/// Called from the main thread, up to once per frame (60 Hz); it rate-limits and layers internally.
///
/// Everything is synthesized in code: a bank of crunch variants (clusters of tiny band-passed fibre
/// snaps over a soft low "crush" layer) is rendered once in the background. Playback is a small pool of
/// `AVAudioPlayerNode`s feeding the main mixer. The engine starts on the first crunch and pauses after
/// a few quiet seconds, so the audio hardware sleeps while nobody touches the leaves.
///
/// Threading: `crunch` only runs the cheap trigger logic on the main thread. Everything that touches
/// AVAudioEngine (building, starting, pausing, scheduling) happens on a private serial queue, because
/// those calls can block for 10-150 ms and would otherwise stall the leaf animation.
final class CrunchAudio {
    /// When false, `crunch` is a no-op and the audio engine is stopped.
    var isEnabled: Bool = true {
        didSet {
            guard oldValue != isEnabled else { return }
            let enabled = isEnabled
            audioQueue.async { [weak self] in self?.setEnabled(enabled) }
        }
    }

    // Main thread.
    private var logic: CrunchTriggerLogic?  // nil until the bank is synthesized

    // Audio queue only.
    private let audioQueue = DispatchQueue(label: "Rustle.CrunchAudio", qos: .userInteractive)
    private var enabled = true
    private var buffers: [AVAudioPCMBuffer] = []
    private var engine: AVAudioEngine?
    private var players: [AVAudioPlayerNode] = []
    private var configObserver: NSObjectProtocol?
    private var retryAfter: Double = 0
    private var soundEndsAt: Double = 0
    private var idleCheckPending = false

    init() {
        audioQueue.async { [weak self] in self?.loadBank() }
        // Pre-build the graph (no audio I/O yet) so the first crunch only pays for start().
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
        guard let logic = logic else { return }  // bank still being synthesized (first moments after launch)
        let now = ProcessInfo.processInfo.systemUptime
        guard let trigger = logic.process(time: now, intensity: intensity, pan: pan) else { return }
        audioQueue.async { [weak self] in self?.play(trigger, requestedAt: now) }
    }

    // MARK: Audio queue

    private func loadBank() {
        guard let format = CrunchTuning.bufferFormat else { return }
        let bank = CrunchSynth.makeBank(seed: CrunchTuning.bankSeed)
        let preroll = CrunchTuning.prerollFrames
        var made: [AVAudioPCMBuffer] = []
        for variant in bank {
            let frames = AVAudioFrameCount(preroll + variant.samples.count)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                  let channel = buffer.floatChannelData?[0] else { return }
            buffer.frameLength = frames
            channel.initialize(repeating: 0, count: preroll)
            variant.samples.withUnsafeBufferPointer { src in
                (channel + preroll).update(from: src.baseAddress!, count: src.count)
            }
            made.append(buffer)
        }
        buffers = made
        let logic = CrunchTriggerLogic(bank: bank, voices: CrunchTuning.voiceCount,
                                       seed: UInt64.random(in: 1...UInt64.max))
        DispatchQueue.main.async { [weak self] in self?.logic = logic }
    }

    private func setEnabled(_ value: Bool) {
        enabled = value
        if !value { tearDownEngine() }
    }

    private func play(_ trigger: CrunchTrigger, requestedAt time: Double) {
        guard enabled, trigger.variant < buffers.count else { return }
        guard let engine = runningEngine() else { return }
        // A trigger that waited behind a slow engine start is dropped rather than bunched up late.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - time < 0.15, trigger.voice < players.count else { return }
        let player = players[trigger.voice]
        if !player.isPlaying {
            guard engine.isRunning else { return }  // play() on a stopped engine raises
            player.play()  // players start lazily: each play() blocks ~10 ms
        }
        // The mixer ramps volume/pan changes over ~13 ms; each buffer starts with that much silence,
        // so the ramp has settled before the first snap.
        player.volume = trigger.volume
        player.pan = trigger.pan
        player.scheduleBuffer(buffers[trigger.variant], at: nil, options: [], completionHandler: nil)
        soundEndsAt = max(soundEndsAt, now + trigger.duration)
        scheduleIdleCheck(after: CrunchTuning.idleTimeout + trigger.duration)
    }

    /// Builds (if needed) and starts the engine. Fails silently, with a back-off, when there is no usable output.
    private func runningEngine() -> AVAudioEngine? {
        if let engine = engine, engine.isRunning { return engine }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= retryAfter else { return nil }
        if engine == nil { buildEngine() }
        guard let engine = engine else {
            retryAfter = now + CrunchTuning.retryDelay
            return nil
        }
        do {
            try engine.start()
        } catch {
            tearDownEngine()
            retryAfter = now + CrunchTuning.retryDelay
            return nil
        }
        return engine.isRunning ? engine : nil
    }

    private func buildEngine() {
        guard let format = CrunchTuning.bufferFormat else { return }
        let engine = AVAudioEngine()
        // Never touch inputNode (that would ask for the microphone). Check the output first:
        // connecting to an output with no channels / no sample rate raises an exception.
        let output = engine.outputNode.outputFormat(forBus: 0)
        guard output.sampleRate > 0, output.channelCount > 0 else { return }
        let mixer = engine.mainMixerNode
        var made: [AVAudioPlayerNode] = []
        for _ in 0..<CrunchTuning.voiceCount {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: mixer, format: format)  // the mixer resamples 48 kHz to the device rate
            made.append(player)
        }
        mixer.outputVolume = CrunchTuning.masterGain
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
        players = made
    }

    private func tearDownEngine() {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        engine?.stop()
        engine = nil
        players = []
    }

    /// Pauses the engine (stopping the audio hardware) once nothing has played for `idleTimeout`.
    private func scheduleIdleCheck(after delay: Double) {
        guard !idleCheckPending else { return }
        idleCheckPending = true
        audioQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.idleCheckPending = false
            guard let engine = self.engine, engine.isRunning else { return }
            let remaining = self.soundEndsAt + CrunchTuning.idleTimeout - ProcessInfo.processInfo.systemUptime
            if remaining > 0.05 {
                self.scheduleIdleCheck(after: remaining)
            } else {
                engine.pause()  // keeps the graph and the playing players; resume costs ~45 ms
            }
        }
    }
}

// MARK: - Offline rendering (used by the test harness, not by the app)

extension CrunchAudio {
    struct TestTrigger {
        let time: Double
        let variant: Int
        let volume: Float
        let pan: Float
    }

    static var sampleRateForTesting: Double { CrunchTuning.sampleRate }

    var isEngineRunningForTesting: Bool { audioQueue.sync { engine?.isRunning ?? false } }
    var hasEngineForTesting: Bool { audioQueue.sync { engine != nil } }

    /// Posts the configuration-change notification for the current engine, as an output-device switch would.
    func simulateConfigurationChangeForTesting() {
        guard let engine = audioQueue.sync(execute: { self.engine }) else { return }
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
    }

    /// The variant bank exactly as the app synthesizes it (without the silent pre-roll), lightest first.
    static func renderBankForTesting() -> [[Float]] {
        CrunchSynth.makeBank(seed: CrunchTuning.bankSeed).map { $0.samples }
    }

    /// Mixes a sequence of `crunch` calls offline through the same trigger logic, gains and the
    /// mixer's equal-power pan law. Returns stereo at `sampleRateForTesting`.
    static func renderSequenceForTesting(calls: [(time: Double, intensity: Float, pan: Float)],
                                         duration: Double,
                                         seed: UInt64 = 7) -> (left: [Float], right: [Float], triggers: [TestTrigger]) {
        let bank = CrunchSynth.makeBank(seed: CrunchTuning.bankSeed)
        let logic = CrunchTriggerLogic(bank: bank, voices: CrunchTuning.voiceCount, seed: seed)
        let sr = CrunchTuning.sampleRate
        let count = Int(duration * sr)
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        var triggers: [TestTrigger] = []
        for call in calls {
            guard let trig = logic.process(time: call.time, intensity: call.intensity, pan: call.pan) else { continue }
            triggers.append(TestTrigger(time: call.time, variant: trig.variant, volume: trig.volume, pan: trig.pan))
            let angle = (trig.pan + 1) * Float.pi / 4
            let gain = trig.volume * CrunchTuning.masterGain
            let gl = cos(angle) * gain, gr = sin(angle) * gain
            let start = Int(call.time * sr) + CrunchTuning.prerollFrames
            let samples = bank[trig.variant].samples
            for k in 0..<samples.count where start + k < count {
                left[start + k] += samples[k] * gl
                right[start + k] += samples[k] * gr
            }
        }
        return (left, right, triggers)
    }
}

// MARK: - Tuning

fileprivate enum CrunchTuning {
    static let sampleRate: Double = 48_000
    static let bufferFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
    /// Silence before each variant: AVAudioMixer ramps volume/pan changes linearly over ~640 frames.
    static let prerollFrames = 672
    static let voiceCount = 10
    static let masterGain: Float = 0.7
    static let idleTimeout: Double = 3.0
    static let retryDelay: Double = 2.0
    static let bankSeed: UInt64 = 0x5275_7374_6C65  // "Rustle"
}

// MARK: - Trigger logic (rate limiting, layering, variant choice)

fileprivate struct CrunchTrigger {
    let variant: Int
    let voice: Int
    let volume: Float
    let pan: Float
    /// Seconds until the voice is silent again (pre-roll + variant + output-latency margin).
    let duration: Double
}

/// Turns a stream of per-frame `crunch` calls into a natural, irregular sequence of layered crunches.
/// Shared by the live player and the offline renderer so the analysis matches what the app plays.
fileprivate final class CrunchTriggerLogic {
    private let weights: [Float]
    private let durations: [Double]
    private var voiceFreeAt: [Double]
    private var rng: CrunchRNG

    private var lastCall = -Double.infinity
    private var lastTrigger = -Double.infinity
    private var nextGap = 0.0
    private var energy: Float = 0
    private var peak: Float = 0
    private var panSum: Float = 0
    private var calls = 0
    private var recent: [Int] = []

    init(bank: [CrunchVariant], voices: Int, seed: UInt64) {
        weights = bank.map { $0.weight }
        durations = bank.map {
            Double(CrunchTuning.prerollFrames + $0.samples.count) / CrunchTuning.sampleRate + 0.03
        }
        voiceFreeAt = [Double](repeating: -Double.infinity, count: voices)
        rng = CrunchRNG(seed: seed)
    }

    func process(time t: Double, intensity: Float, pan: Float) -> CrunchTrigger? {
        let i = intensity.isFinite ? min(max(intensity, 0), 1) : 0
        let p = pan.isFinite ? min(max(pan, -1), 1) : 0
        if t - lastCall > 0.12 { resetAccumulators() }  // the cursor paused: old contributions are stale
        lastCall = t
        guard i >= 0.02 else { return nil }

        // Accumulate between triggers so a run of tiny calls adds up to one rustle.
        energy += i
        peak = max(peak, i)
        panSum += p * i
        calls += 1
        guard t - lastTrigger >= nextGap, energy >= 0.09 else { return nil }

        let level = min(1, 0.65 * peak + 0.35 * energy / Float(calls))
        let focus = panSum / energy
        resetAccumulators()
        lastTrigger = t
        // Gap shrinks with intensity (~90-170 ms when brushing, ~40-75 ms when ploughing), jittered so
        // the texture never settles into a machine-gun rhythm.
        let base = 0.05 + 0.065 * Double((1 - level) * (1 - level))
        nextGap = base * Double(rng.uniform(0.8, 1.5))

        // Barely-touched leaves (below ~0.06) only rustle now and then.
        if level < 0.06 && rng.unit() > (level / 0.06) * (level / 0.06) {
            nextGap *= 0.6
            return nil
        }
        guard let voice = voiceFreeAt.firstIndex(where: { $0 <= t }) else { return nil }

        var active = 0
        for end in voiceFreeAt where end > t { active += 1 }
        let accent: Bool, contrast: Float
        if active == 0 {
            // An isolated touch (first contact) always gets a full crunch for its intensity.
            accent = false
            contrast = rng.uniform(0.85, 1.05)
        } else {
            // While layering, every few triggers is an accent (a heavier, louder crunch) so fast
            // ploughing keeps distinct crunches instead of blurring into a wall of noise.
            accent = rng.unit() < 0.12 + 0.18 * level
            contrast = accent ? rng.uniform(1.0, 1.15) : rng.uniform(0.45, 0.85)
        }
        let variant = pickVariant(level: accent ? min(1, level + 0.15) : level)
        // Soft loudness cap: each extra overlapping voice pulls the new one down a little.
        let layering = 1 / (1 + 0.22 * Float(active)).squareRoot()
        let volume = (0.5 + 0.5 * pow(level, 0.9)) * contrast * layering
        let outPan = min(max(focus * 0.8 + rng.uniform(-0.08, 0.08), -0.85), 0.85)

        voiceFreeAt[voice] = t + durations[variant]
        recent.append(variant)
        if recent.count > 3 { recent.removeFirst() }
        return CrunchTrigger(variant: variant, voice: voice, volume: volume, pan: outPan,
                             duration: durations[variant])
    }

    private func resetAccumulators() {
        energy = 0
        peak = 0
        panSum = 0
        calls = 0
    }

    /// Weighted pick of a variant whose weight is near the (jittered) level, never one of the last three.
    private func pickVariant(level: Float) -> Int {
        let target = min(max(level + rng.uniform(-0.12, 0.12), 0), 1)
        var total: Float = 0
        for (k, w) in weights.enumerated() where !recent.contains(k) {
            let d = (w - target) / 0.14
            total += exp(-d * d)
        }
        var pick = rng.unit() * total
        var fallback = 0
        for (k, w) in weights.enumerated() where !recent.contains(k) {
            let d = (w - target) / 0.14
            pick -= exp(-d * d)
            fallback = k
            if pick <= 0 { return k }
        }
        return fallback
    }
}

// MARK: - Synthesis

fileprivate struct CrunchVariant {
    let samples: [Float]
    /// 0 = faint papery rustle ... 1 = big dense crunch.
    let weight: Float
}

fileprivate enum CrunchSynth {
    static let variantCount = 24

    static func makeBank(seed: UInt64) -> [CrunchVariant] {
        (0..<variantCount).map { k in
            var rng = CrunchRNG(seed: seed &+ UInt64(k + 1) &* 0x9E37_79B9_7F4A_7C15)
            let weight = Float(k) / Float(variantCount - 1)
            return CrunchVariant(samples: makeVariant(weight: weight, rng: &rng), weight: weight)
        }
    }

    /// One crunch: 1-3 compressions, each a cluster of fibre snaps that is densest at its start and
    /// thins out; a bed of faint papery micro-grains; and a soft low crush layer that follows the snaps.
    static func makeVariant(weight w: Float, rng: inout CrunchRNG) -> [Float] {
        let sr = Float(CrunchTuning.sampleRate)
        let duration = min(0.40, max(0.075, (0.08 + 0.26 * pow(w, 0.85)) * rng.uniform(0.85, 1.15)))
        let n = Int(duration * sr)
        let bright = rng.uniform(0.88, 1.14)  // per-variant timbre, stands in for pitch variety

        struct Burst { let onset: Float; let length: Float; let strength: Float }
        var bursts = [Burst(onset: rng.uniform(0.0016, 0.004), length: duration * rng.uniform(0.3, 0.5), strength: 1)]
        let extra: Int
        if w < 0.3 { extra = rng.unit() < 0.25 ? 1 : 0 } else if w < 0.7 { extra = 1 } else { extra = rng.unit() < 0.25 ? 2 : 1 }
        for _ in 0..<extra {
            let onset = duration * rng.uniform(0.08, 0.35)
            bursts.append(Burst(onset: onset, length: (duration - onset) * rng.uniform(0.25, 0.5),
                                strength: rng.uniform(0.4, 0.8)))
        }

        // Activity envelope: drives the paper grains and the crush layer.
        var activity = [Float](repeating: 0, count: n)
        for b in bursts {
            let start = Int(b.onset * sr), attack = max(1, Int(0.003 * sr)), tau = 0.25 * b.length * sr
            for k in max(0, start)..<n {
                let x = Float(k - start)
                activity[k] += b.strength * min(1, x / Float(attack)) * exp(-x / tau)
            }
        }

        // 1) Fibre snaps.
        var snaps = [Float](repeating: 0, count: n)
        let snapCount = Int((20 + 170 * pow(w, 1.1)) * rng.uniform(0.8, 1.2))
        let totalStrength = bursts.reduce(0) { $0 + $1.strength }
        let spread = 2.4 - 1.0 * w  // light rustles: a few louder ticks among small ones; crunches: fuller
        for b in bursts {
            let count = Int(Float(snapCount) * b.strength / totalStrength)
            for _ in 0..<count {
                let pos = pow(rng.unit(), 1.9)
                let amp = b.strength * (0.12 + 0.88 * pow(rng.unit(), spread)) * (1 - 0.55 * pos)
                addSnap(&snaps, at: Int((b.onset + b.length * pos) * sr), amp: amp, bright: bright, rng: &rng)
            }
        }
        let settling = Int((2 + 18 * w) * rng.uniform(0.7, 1.3))
        for _ in 0..<settling {
            let pos = rng.uniform(0.25, 0.92)
            addSnap(&snaps, at: Int(pos * duration * sr), amp: rng.uniform(0.04, 0.22) * (1.2 - pos),
                    bright: bright, rng: &rng)
        }

        // 2) Paper grain: dense, faint micro-grains that follow the activity envelope.
        var grains = [Float](repeating: 0, count: n)
        let peakActivity = max(activity.max() ?? 1, 1e-6)
        let grainTries = Int((1500 + 2500 * w) * duration)
        for _ in 0..<grainTries {
            let k = Int(rng.unit() * Float(n - 1))
            let a = activity[k] / peakActivity
            guard rng.unit() < a else { continue }
            addGrain(&grains, at: k, amp: a * rng.uniform(0.25, 1), bright: bright, rng: &rng)
        }

        // 3) Crush body: low band-passed noise shaped by the activity and by the snaps themselves.
        var snapEnv = [Float](repeating: 0, count: n)
        var follower: Float = 0
        let rel = exp(-1 / (0.006 * sr))
        for k in 0..<n {
            let x = abs(snaps[k])
            follower = x > follower ? x : follower * rel
            snapEnv[k] = follower
        }
        let snapEnvPeak = max(snapEnv.max() ?? 1, 1e-6)
        var body = [Float](repeating: 0, count: n)
        let bodyFc = (650 + 650 * w) * rng.uniform(0.85, 1.15)
        var lp1 = CrunchBiquad.lowpass(bodyFc, q: 0.8), lp2 = CrunchBiquad.lowpass(bodyFc, q: 0.6)
        var hp = CrunchBiquad.highpass(170 + 90 * w, q: 0.7)
        let bodyAttack = rng.uniform(0.004, 0.012) * sr, bodyTau = (0.022 + 0.04 * w) * sr
        let bodyStart = Int(bursts[0].onset * sr)
        for k in 0..<n {
            let noise = hp.process(lp2.process(lp1.process(rng.bipolar())))
            let x = Float(max(0, k - bodyStart))
            let env = min(1, x / bodyAttack) * (0.6 * exp(-x / bodyTau) + 0.4 * activity[k] / peakActivity)
            body[k] = noise * env * (0.35 + 0.65 * min(1, 2 * snapEnv[k] / snapEnvPeak))
        }

        // Mix by RMS ratios relative to the snaps.
        let snapRMS = rms(snaps)
        let grainRatio = dB(-9 - 6 * w), bodyRatio = dB(-13 + 8 * w)
        let gGrain = snapRMS * grainRatio / max(rms(grains), 1e-9)
        let gBody = snapRMS * bodyRatio / max(rms(body), 1e-9)
        var out = [Float](repeating: 0, count: n)
        var air = CrunchBiquad.lowpass(11_000, q: 0.707)
        for k in 0..<n { out[k] = air.process(snaps[k] + gGrain * grains[k] + gBody * body[k]) }

        // Loudness: onset RMS from -22 dBFS (rustle) to -18 dBFS (crunch); the odd outlier snap is
        // then smoothly limited so peaks stay below -4.4 dBFS before any layering.
        let onsetRMS = rms(out[0..<min(n, Int(0.12 * sr))])
        let gain = dB(-22 + 4 * w) / max(onsetRMS, 1e-9)
        for k in 0..<n { out[k] *= gain }
        limitPeaks(&out, ceiling: 0.6)

        // DC blocker (30 Hz), then click-free edges: 1.5 ms fade-in, 15 ms fade-out (raised cosine).
        var dcX: Float = 0, dcY: Float = 0
        let dcR = exp(-2 * Float.pi * 30 / sr)
        for k in 0..<n {
            dcY = out[k] - dcX + dcR * dcY
            dcX = out[k]
            out[k] = dcY
        }
        let fadeIn = Int(0.0015 * sr), fadeOut = Int(0.015 * sr)
        for k in 0..<fadeIn { out[k] *= 0.5 - 0.5 * cos(Float.pi * Float(k) / Float(fadeIn)) }
        for k in 0..<fadeOut { out[n - 1 - k] *= 0.5 - 0.5 * cos(Float.pi * Float(k) / Float(fadeOut)) }

        // A few ms of leading silence, different per variant, so onsets don't all land on the 60 Hz call grid.
        let offset = Int(rng.uniform(0, 0.009) * sr)
        return [Float](repeating: 0, count: offset) + out
    }

    /// Offline look-ahead limiter: the gain envelope dips smoothly (~1 ms) around any sample above `ceiling`.
    static func limitPeaks(_ x: inout [Float], ceiling: Float) {
        let n = x.count, reach = 48  // 1 ms
        // Running minimum (+-reach) of the gain each over-ceiling sample needs...
        var floor = [Float](repeating: 1, count: n)
        var any = false
        for k in 0..<n where abs(x[k]) > ceiling {
            any = true
            let g = ceiling / abs(x[k])
            for j in max(0, k - reach)...min(n - 1, k + reach) where g < floor[j] { floor[j] = g }
        }
        guard any else { return }
        // ...then a centred box average half as wide: smooth, and never above what a peak needs.
        var prefix = [Double](repeating: 0, count: n + 1)
        for k in 0..<n { prefix[k + 1] = prefix[k] + Double(floor[k]) }
        let h = reach / 2
        for k in 0..<n {
            let a = max(0, k - h), b = min(n, k + h + 1)
            x[k] *= Float((prefix[b] - prefix[a]) / Double(b - a))
        }
    }

    /// A fibre snap: either a short noise burst through a resonant band-pass, or a tiny damped "tick".
    static func addSnap(_ buf: inout [Float], at start: Int, amp: Float, bright: Float, rng: inout CrunchRNG) {
        guard start >= 0, start < buf.count else { return }
        let sr = Float(CrunchTuning.sampleRate)
        let fc = min(10_500, rng.logUniform(1500, 9000) * bright)
        let level = amp * pow(3000 / fc, 0.15)  // slight tilt so the top end stays crisp, not harsh
        if rng.unit() < 0.3 {
            let tau = rng.uniform(0.00012, 0.0006) * sr
            let len = min(buf.count - start, Int(tau * 6))
            let omega = 2 * Float.pi * fc / sr
            let phase = rng.uniform(0, 2 * Float.pi)
            for k in 0..<len {
                let x = Float(k)
                buf[start + k] += 0.8 * level * min(1, x / 2) * exp(-x / tau) * sin(phase + omega * x)
            }
        } else {
            let q = rng.uniform(1.0, 4.5)
            let burst = max(4, Int(rng.logUniform(0.0004, 0.004) * sr))
            let ring = Int(3 * q / (Float.pi * fc) * sr)
            let total = min(buf.count - start, burst + ring)
            var filter = CrunchBiquad.bandpass(fc, q: q)
            let norm = 0.33 / ((Float.pi / 2) * (fc / q) / (sr / 2)).squareRoot()
            let attack = max(2, Int(0.00008 * sr))
            let tau = Float(burst) / 3.5
            for k in 0..<total {
                var x: Float = 0
                if k < burst {
                    x = rng.bipolar() * 1.732 * min(1, Float(k) / Float(attack)) * exp(-Float(k) / tau)
                }
                buf[start + k] += level * norm * filter.process(x)
            }
        }
    }

    /// A papery micro-grain: 0.15-0.7 ms of band-passed noise in the upper range.
    static func addGrain(_ buf: inout [Float], at start: Int, amp: Float, bright: Float, rng: inout CrunchRNG) {
        let sr = Float(CrunchTuning.sampleRate)
        let fc = min(10_000, rng.logUniform(2500, 9000) * bright)
        let q = rng.uniform(1.2, 2.5)
        let len = max(4, Int(rng.uniform(0.00015, 0.0007) * sr))
        let total = min(buf.count - start, len + Int(2 * q / (Float.pi * fc) * sr))
        guard total > 0 else { return }
        var filter = CrunchBiquad.bandpass(fc, q: q)
        for k in 0..<total {
            let x: Float = k < len ? rng.bipolar() * sin(Float.pi * Float(k) / Float(len)) : 0
            buf[start + k] += amp * filter.process(x)
        }
    }

    static func rms<C: Collection>(_ x: C) -> Float where C.Element == Float {
        guard !x.isEmpty else { return 0 }
        var sum: Float = 0
        for v in x { sum += v * v }
        return (sum / Float(x.count)).squareRoot()
    }

    static func dB(_ value: Float) -> Float { pow(10, value / 20) }
}

/// RBJ biquad, transposed direct form II.
fileprivate struct CrunchBiquad {
    private var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    private var z1: Float = 0, z2: Float = 0

    private init(_ b0: Double, _ b1: Double, _ b2: Double, _ a0: Double, _ a1: Double, _ a2: Double) {
        self.b0 = Float(b0 / a0); self.b1 = Float(b1 / a0); self.b2 = Float(b2 / a0)
        self.a1 = Float(a1 / a0); self.a2 = Float(a2 / a0)
    }

    private static func omega(_ fc: Float) -> (cos: Double, alphaPerQ: Double) {
        let w = 2 * Double.pi * Double(fc) / CrunchTuning.sampleRate
        return (Foundation.cos(w), Foundation.sin(w) / 2)
    }

    /// Band-pass with 0 dB peak gain.
    static func bandpass(_ fc: Float, q: Float) -> CrunchBiquad {
        let (c, s) = omega(fc), alpha = s / Double(q)
        return CrunchBiquad(alpha, 0, -alpha, 1 + alpha, -2 * c, 1 - alpha)
    }

    static func lowpass(_ fc: Float, q: Float) -> CrunchBiquad {
        let (c, s) = omega(fc), alpha = s / Double(q)
        return CrunchBiquad((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + alpha, -2 * c, 1 - alpha)
    }

    static func highpass(_ fc: Float, q: Float) -> CrunchBiquad {
        let (c, s) = omega(fc), alpha = s / Double(q)
        return CrunchBiquad((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + alpha, -2 * c, 1 - alpha)
    }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

/// SplitMix64: tiny, fast and deterministic, so the bank sounds the same on every launch.
fileprivate struct CrunchRNG {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Float { Float(next() >> 40) * (1 / 16_777_216) }
    mutating func uniform(_ a: Float, _ b: Float) -> Float { a + (b - a) * unit() }
    mutating func bipolar() -> Float { unit() * 2 - 1 }
    mutating func logUniform(_ a: Float, _ b: Float) -> Float { a * pow(b / a, unit()) }
}
