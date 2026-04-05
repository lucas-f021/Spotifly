//
//  Equalizer.swift
//  Spotifly
//
//  6-band graphic EQ applied to the PCM stream in AudioRenderer.feedRenderer().
//  DSP: Direct Form II Transposed biquad filters (RBJ Audio EQ Cookbook).
//  Thread safety: NSLock guards coefficients + state.
//  renderQueue holds the lock for ~20µs per chunk — no audible impact.
//

import Foundation

// MARK: - Biquad Filter

/// Direct Form II Transposed biquad filter with per-channel state.
/// Coefficients are normalized (divided by a0).
private struct BiquadFilter {
    // Normalized feed-forward coefficients
    var b0: Float
    var b1: Float
    var b2: Float
    // Normalized feed-back coefficients (negated, per DFT-II convention)
    var a1: Float
    var a2: Float

    // Per-channel delay state
    var w1L: Float = 0
    var w2L: Float = 0
    var w1R: Float = 0
    var w2R: Float = 0

    /// Identity filter (0dB passthrough)
    static var identity: BiquadFilter {
        BiquadFilter(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)
    }

    /// Process one stereo sample pair in-place.
    @inline(__always)
    nonisolated mutating func process(left: inout Float, right: inout Float) {
        let yL = b0 * left + w1L
        w1L = b1 * left - a1 * yL + w2L
        w2L = b2 * left - a2 * yL
        left = yL

        let yR = b0 * right + w1R
        w1R = b1 * right - a1 * yR + w2R
        w2R = b2 * right - a2 * yR
        right = yR
    }

    /// Zero delay state (call when enabling/disabling to avoid transients)
    nonisolated mutating func resetState() {
        w1L = 0; w2L = 0; w1R = 0; w2R = 0
    }
}

// MARK: - Equalizer

final class Equalizer: @unchecked Sendable {
    // MARK: - Band Definitions

    enum FilterType { case lowShelf, peaking, highShelf }

    struct Band {
        let frequency: Float
        let type: FilterType
    }

    nonisolated(unsafe) static let bands: [Band] = [
        Band(frequency:    60, type: .lowShelf),
        Band(frequency:   150, type: .peaking),
        Band(frequency:   400, type: .peaking),
        Band(frequency:  1000, type: .peaking),
        Band(frequency:  2400, type: .peaking),
        Band(frequency: 15000, type: .highShelf),
    ]

    nonisolated(unsafe) static let bandCount = 6
    nonisolated(unsafe) static let gainRange: ClosedRange<Float> = -12...12

    // MARK: - State
    // All stored properties are nonisolated(unsafe) — the NSLock provides thread safety.

    nonisolated(unsafe) private let lock = NSLock()
    nonisolated(unsafe) private var filters: [BiquadFilter]
    nonisolated(unsafe) private(set) var isEnabled: Bool
    nonisolated(unsafe) private var gains: [Float] // dB, one per band

    private nonisolated(unsafe) static let sampleRate: Float = 44100
    private nonisolated(unsafe) static let peakingQ: Float = 1.0
    private nonisolated(unsafe) static let shelfSlope: Float = 1.0

    // MARK: - Init

    /// Initializes with flat response (all bands 0dB, disabled).
    /// The UI layer must call setGain/setEnabled at startup to restore persisted state.
    nonisolated init() {
        gains = [Float](repeating: 0, count: Self.bandCount)
        isEnabled = false
        filters = Self.makeFilters(gains: gains)
    }

    // MARK: - Public API (called from main thread)

    /// Update gain for a single band. Recomputes coefficients immediately.
    nonisolated func setGain(_ gain: Float, forBand index: Int) {
        guard (0 ..< Self.bandCount).contains(index) else { return }
        let clamped = max(Self.gainRange.lowerBound, min(Self.gainRange.upperBound, gain))
        lock.lock()
        gains[index] = clamped
        let newFilters = Self.makeFilters(gains: gains)
        for i in 0 ..< filters.count {
            // Preserve delay state — avoids pop when gain changes during playback
            var f = newFilters[i]
            f.w1L = filters[i].w1L
            f.w2L = filters[i].w2L
            f.w1R = filters[i].w1R
            f.w2R = filters[i].w2R
            filters[i] = f
        }
        lock.unlock()
    }

    nonisolated func setEnabled(_ enabled: Bool) {
        lock.lock()
        isEnabled = enabled
        if !enabled {
            for i in 0 ..< filters.count { filters[i].resetState() }
        }
        lock.unlock()
    }

    /// Current gain for a band (for reading back into UI).
    nonisolated func gain(forBand index: Int) -> Float {
        lock.lock()
        defer { lock.unlock() }
        return gains[index]
    }

    /// Reset all bands to 0dB.
    nonisolated func reset() {
        lock.lock()
        gains = [Float](repeating: 0, count: Self.bandCount)
        filters = Self.makeFilters(gains: gains)
        lock.unlock()
    }

    // MARK: - DSP (called from renderQueue)

    /// Process an interleaved stereo Float32 buffer in-place.
    /// `count` is the total number of floats (frames × 2 channels).
    nonisolated func process(_ ptr: UnsafeMutablePointer<Float>, count: Int) {
        lock.lock()
        defer { lock.unlock() }

        var i = 0
        let limit = count - 1
        while i < limit {
            for j in 0 ..< filters.count {
                filters[j].process(left: &ptr[i], right: &ptr[i + 1])
            }
            i += 2
        }
    }

    // MARK: - Coefficient Math (RBJ Audio EQ Cookbook)

    private nonisolated static func makeFilters(gains: [Float]) -> [BiquadFilter] {
        (0 ..< bandCount).map { i in
            makeFilter(type: bands[i].type, frequency: bands[i].frequency, gainDB: gains[i])
        }
    }

    private nonisolated static func makeFilter(type: FilterType, frequency: Float, gainDB: Float) -> BiquadFilter {
        // A = 10^(dBgain/40) — amplitude ratio for the given dB gain
        let A = pow(10, gainDB / 40)
        let w0 = 2 * Float.pi * frequency / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)

        let b0, b1, b2, a0, a1, a2: Float

        switch type {
        case .peaking:
            let alpha = sinW0 / (2 * peakingQ)
            b0 = 1 + alpha * A
            b1 = -2 * cosW0
            b2 = 1 - alpha * A
            a0 = 1 + alpha / A
            a1 = -2 * cosW0
            a2 = 1 - alpha / A

        case .lowShelf:
            let alpha = sinW0 / 2 * sqrt((A + 1 / A) * (1 / shelfSlope - 1) + 2)
            let sqrtA = sqrt(A)
            b0 =      A * ((A + 1) - (A - 1) * cosW0 + 2 * sqrtA * alpha)
            b1 =  2 * A * ((A - 1) - (A + 1) * cosW0)
            b2 =      A * ((A + 1) - (A - 1) * cosW0 - 2 * sqrtA * alpha)
            a0 =          (A + 1) + (A - 1) * cosW0 + 2 * sqrtA * alpha
            a1 =     -2 * ((A - 1) + (A + 1) * cosW0)
            a2 =          (A + 1) + (A - 1) * cosW0 - 2 * sqrtA * alpha

        case .highShelf:
            let alpha = sinW0 / 2 * sqrt((A + 1 / A) * (1 / shelfSlope - 1) + 2)
            let sqrtA = sqrt(A)
            b0 =      A * ((A + 1) + (A - 1) * cosW0 + 2 * sqrtA * alpha)
            b1 = -2 * A * ((A - 1) + (A + 1) * cosW0)
            b2 =      A * ((A + 1) + (A - 1) * cosW0 - 2 * sqrtA * alpha)
            a0 =          (A + 1) - (A - 1) * cosW0 + 2 * sqrtA * alpha
            a1 =      2 * ((A - 1) - (A + 1) * cosW0)
            a2 =          (A + 1) - (A - 1) * cosW0 - 2 * sqrtA * alpha
        }

        // Normalize by a0
        return BiquadFilter(
            b0: b0 / a0,
            b1: b1 / a0,
            b2: b2 / a0,
            a1: a1 / a0,
            a2: a2 / a0,
        )
    }
}
