//
//  VideoCuttingAudioProcessingEngine.swift
//  DemoFlow
//
//  Created by PJ Lee + Ai on 2026/5/5.
//

import AVFoundation
import CoreMedia
import MediaToolbox
import Foundation

final class VideoCuttingAudioProcessingEngine {
    func makeAudioMixIfNeeded(
        track: AVAssetTrack?,
        config: VideoCuttingAudioProcessingConfig
    ) throws -> AVAudioMix? {
        let normalized = config.clamped
        guard normalized.hasAnyProcessing else { return nil }
        guard let track else { return nil }

        let tap = try createTap(config: normalized)
        let input = AVMutableAudioMixInputParameters(track: track)
        input.audioTapProcessor = tap

        let mix = AVMutableAudioMix()
        mix.inputParameters = [input]
        return mix
    }

    private func createTap(config: VideoCuttingAudioProcessingConfig) throws -> MTAudioProcessingTap {
        let state = TapState(config: config)

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(state).toOpaque(),
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: tapUnprepare,
            process: tapProcess
        )

        var tapRef: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PreEffects,
            &tapRef
        )
        guard status == noErr, let tapRef else {
            throw AudioProcessingError.createTapFailed(status)
        }
        return tapRef
    }
}

private final class TapState {
    var config: VideoCuttingAudioProcessingConfig
    private var isSupportedFormat = true
    private var sampleRate: Float = 48_000
    private var channelStates: [ChannelState] = []
    private var humDetectionSamples: [Float] = []
    private var detectedHumBaseHz: Float?
    private let humDetectionWindow = 4096
    private let maxHumHarmonics = 4

    init(config: VideoCuttingAudioProcessingConfig) {
        self.config = config.clamped
    }

    func prepare(_ processingFormat: AudioStreamBasicDescription) {
        let isLinearPCM = processingFormat.mFormatID == kAudioFormatLinearPCM
        let isFloat = (processingFormat.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let bitsPerChannel = processingFormat.mBitsPerChannel
        isSupportedFormat = isLinearPCM && isFloat && bitsPerChannel == 32
        sampleRate = max(8_000, Float(processingFormat.mSampleRate))
        channelStates.removeAll(keepingCapacity: false)
        humDetectionSamples.removeAll(keepingCapacity: false)
        detectedHumBaseHz = nil
    }

    func process(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: CMItemCount) {
        guard isSupportedFormat else { return }
        let cfg = config.clamped
        let denoise = Float(cfg.noiseReductionEnabled ? cfg.noiseReductionPercent / 100.0 : 0)
        let params = eqPresetParams(cfg.eqPreset)
        let useBalancedCleanup = (cfg.eqPreset == .balanced) && denoise > 0.001

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard !buffers.isEmpty else { return }

        for (channelIndex, buffer) in buffers.enumerated() {
            guard let mData = buffer.mData else { continue }
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let channelCount = max(1, Int(buffer.mNumberChannels))
            let validFrames = min(sampleCount / channelCount, Int(frameCount))
            guard validFrames > 0 else { continue }
            ensureChannelState(index: channelIndex)

            let samples = mData.bindMemory(to: Float.self, capacity: sampleCount)
            var state = channelStates[channelIndex]
            var dryPeak: Float = 0
            var wetPeak: Float = 0
            var drySamples = Array<Float>(repeating: 0, count: sampleCount)

            for frame in 0..<validFrames {
                for interleaveChannel in 0..<channelCount {
                    let i = frame * channelCount + interleaveChannel
                    guard i < sampleCount else { continue }

                    var sample = samples[i]
                    let drySample = sample
                    drySamples[i] = drySample
                    dryPeak = max(dryPeak, abs(drySample))

                    if useBalancedCleanup {
                        if channelIndex == 0 {
                            collectHumSample(sample)
                            if detectedHumBaseHz == nil, humDetectionSamples.count >= humDetectionWindow {
                                let detected = detectHumBaseFrequency(from: humDetectionSamples)
                                detectedHumBaseHz = detected ?? 50
                                resetHumNotchesOnAllChannels(baseFrequency: detectedHumBaseHz)
                            }
                        }

                        let hpCutoff: Float = 55 + denoise * 70
                        var cleaned = applyDCBlock(sample, state: &state)
                        cleaned = applyOnePoleHighPass(cleaned, cutoffHz: hpCutoff, state: &state)
                        cleaned = applyHumNotchFilters(cleaned, state: &state)
                        let lpCutoff: Float = max(7_500, 15_500 - denoise * 6_000)
                        cleaned = applyOnePoleLowPass(cleaned, cutoffHz: lpCutoff, state: &state)

                        if cleaned.isFinite {
                            let mix: Float = 0.30 + denoise * 0.50
                            sample = drySample * (1 - mix) + cleaned * mix
                        } else {
                            sample = drySample
                        }
                    }

                    if params.speechCleanupTuned {
                        if channelIndex == 0 {
                            collectHumSample(sample)
                            if detectedHumBaseHz == nil, humDetectionSamples.count >= humDetectionWindow {
                                detectedHumBaseHz = detectHumBaseFrequency(from: humDetectionSamples)
                                resetHumNotchesOnAllChannels(baseFrequency: detectedHumBaseHz)
                            }
                        }

                        sample = applyDCBlock(sample, state: &state)
                        sample = applyOnePoleHighPass(sample, cutoffHz: 80, state: &state)
                        sample = applyOnePoleLowPass(sample, cutoffHz: 10_500, state: &state)
                        sample = applyHumNotchFilters(sample, state: &state)

                        let absSample = abs(sample)
                        updateAdaptiveNoiseFloor(absSample, state: &state)
                        updateSpeechEnvelope(absSample, state: &state)

                        let noiseThreshold = state.noiseFloor * (1.12 + denoise * 1.35) + 0.00015
                        let targetGateGain: Float
                        if state.speechEnvelope < noiseThreshold {
                            // 保守门控：宁可保留部分底噪，也避免把人声压没。
                            targetGateGain = max(0.45, 1.0 - denoise * 0.52)
                        } else if state.speechEnvelope > noiseThreshold * 1.22 {
                            targetGateGain = 1.0
                        } else {
                            targetGateGain = max(0.72, 1.0 - denoise * 0.26)
                        }
                        let gateSmoothing: Float = targetGateGain < state.gateGain ? 0.08 : 0.04
                        state.gateGain += (targetGateGain - state.gateGain) * gateSmoothing
                        sample *= state.gateGain
                    }

                    state.lowBand += params.lowPassAlpha * (sample - state.lowBand)
                    state.highBand = params.highPassAlpha * (state.highBand + sample - state.highBandPrevInput)
                    state.highBandPrevInput = sample
                    let mid: Float
                    if params.speechCleanupTuned {
                        mid = sample - state.lowBand - state.highBand
                    } else {
                        mid = sample - state.lowBand
                    }
                    sample = state.lowBand * params.lowGain + mid * params.midGain + state.highBand * params.highGain

                    if params.speechCleanupTuned {
                        sample = sample * 0.76 + drySample * 0.24
                        sample *= (1.0 + denoise * 0.08)
                    }

                    let drive: Float = params.speechCleanupTuned
                        ? (1 + denoise * 0.22)
                        : (1 + denoise * 0.35)
                    sample = tanh(sample * drive)

                    // 强兜底：任何异常值或近似静音都回退到干声，优先保证可听见。
                    if !sample.isFinite {
                        sample = drySample
                    }
                    wetPeak = max(wetPeak, abs(sample))
                    samples[i] = sample
                }
            }

            if dryPeak > 0.002, wetPeak < 0.000_05 {
                for frame in 0..<validFrames {
                    for interleaveChannel in 0..<channelCount {
                        let i = frame * channelCount + interleaveChannel
                        guard i < sampleCount else { continue }
                        // 在极端误判导致近静音时，直接回退干声，优先保证可听见。
                        samples[i] = drySamples[i]
                    }
                }
            }
            channelStates[channelIndex] = state
        }
    }

    private func ensureChannelState(index: Int) {
        if index < channelStates.count { return }
        for _ in channelStates.count...index {
            channelStates.append(ChannelState())
        }
    }

    private func collectHumSample(_ sample: Float) {
        guard humDetectionSamples.count < humDetectionWindow else { return }
        humDetectionSamples.append(sample)
    }

    private func detectHumBaseFrequency(from samples: [Float]) -> Float? {
        guard samples.count >= 512 else { return nil }
        let candidates: [Float] = [50, 60]
        var bestFreq: Float?
        var bestEnergy: Float = 0
        for freq in candidates {
            var energy: Float = 0
            for offset: Float in [-1, 0, 1] {
                energy += goertzelPower(samples: samples, frequency: freq + offset, sampleRate: sampleRate)
            }
            if energy > bestEnergy {
                bestEnergy = energy
                bestFreq = freq
            }
        }

        guard let bestFreq else { return nil }
        let energyPerSample = bestEnergy / Float(samples.count)
        return energyPerSample > 0.000_008 ? bestFreq : nil
    }

    private func goertzelPower(samples: [Float], frequency: Float, sampleRate: Float) -> Float {
        let omega = (2 * Float.pi * frequency) / sampleRate
        let coeff = 2 * cos(omega)
        var q0: Float = 0
        var q1: Float = 0
        var q2: Float = 0
        for sample in samples {
            q0 = coeff * q1 - q2 + sample
            q2 = q1
            q1 = q0
        }
        return max(0, q1 * q1 + q2 * q2 - coeff * q1 * q2)
    }

    private func resetHumNotchesOnAllChannels(baseFrequency: Float?) {
        for index in channelStates.indices {
            channelStates[index].humNotches.removeAll(keepingCapacity: false)
        }
        guard let baseFrequency else { return }
        for index in channelStates.indices {
            channelStates[index].humNotches = makeHumNotches(baseFrequency: baseFrequency)
        }
    }

    private func makeHumNotches(baseFrequency: Float) -> [BiquadNotchState] {
        var filters: [BiquadNotchState] = []
        for harmonic in 1...maxHumHarmonics {
            let frequency = baseFrequency * Float(harmonic)
            if frequency >= 0.46 * sampleRate { break }
            filters.append(BiquadNotchState(centerFrequency: frequency, sampleRate: sampleRate, q: 40))
        }
        return filters
    }

    private func applyDCBlock(_ sample: Float, state: inout ChannelState) -> Float {
        let r: Float = 0.995
        let y = sample - state.dcPrevInput + r * state.dcPrevOutput
        state.dcPrevInput = sample
        state.dcPrevOutput = y
        return y
    }

    private func applyOnePoleHighPass(_ sample: Float, cutoffHz: Float, state: inout ChannelState) -> Float {
        let rc = 1 / (2 * Float.pi * cutoffHz)
        let dt = 1 / sampleRate
        let alpha = rc / (rc + dt)
        let y = alpha * (state.hpPrevOutput + sample - state.hpPrevInput)
        state.hpPrevInput = sample
        state.hpPrevOutput = y
        return y
    }

    private func applyOnePoleLowPass(_ sample: Float, cutoffHz: Float, state: inout ChannelState) -> Float {
        let x = expf(-2 * Float.pi * cutoffHz / sampleRate)
        let alpha = 1 - x
        state.lpOutput += alpha * (sample - state.lpOutput)
        return state.lpOutput
    }

    private func applyHumNotchFilters(_ sample: Float, state: inout ChannelState) -> Float {
        guard !state.humNotches.isEmpty else { return sample }
        var value = sample
        for index in state.humNotches.indices {
            value = state.humNotches[index].process(value)
        }
        return value
    }

    private func updateAdaptiveNoiseFloor(_ absoluteSample: Float, state: inout ChannelState) {
        let fastRise: Float = 0.0035
        let slowFall: Float = 0.030
        if absoluteSample < state.noiseFloor {
            state.noiseFloor += (absoluteSample - state.noiseFloor) * slowFall
        } else {
            state.noiseFloor += (absoluteSample - state.noiseFloor) * fastRise
        }
        state.noiseFloor = max(0.000_15, min(0.25, state.noiseFloor))
    }

    private func updateSpeechEnvelope(_ absoluteSample: Float, state: inout ChannelState) {
        let attack: Float = 0.18
        let release: Float = 0.012
        let coeff: Float = absoluteSample > state.speechEnvelope ? attack : release
        state.speechEnvelope += (absoluteSample - state.speechEnvelope) * coeff
    }

    private func eqPresetParams(_ preset: VideoCuttingAudioEQPreset) -> EQParams {
        switch preset {
        case .balanced:
            return EQParams(
                lowGain: 0.68,
                midGain: 1.32,
                highGain: 0.84,
                lowPassAlpha: 0.10,
                highPassAlpha: 0.09,
                speechCleanupTuned: false
            )
        case .vocalBoost:
            return EQParams(lowGain: 0.9, midGain: 1.22, highGain: 1.1, lowPassAlpha: 0.11, highPassAlpha: 0.07)
        case .musicBoost:
            return EQParams(lowGain: 1.14, midGain: 1.0, highGain: 1.12, lowPassAlpha: 0.12, highPassAlpha: 0.06)
        case .loudness:
            return EQParams(lowGain: 1.2, midGain: 1.12, highGain: 1.15, lowPassAlpha: 0.13, highPassAlpha: 0.065)
        case .humReduction:
            return EQParams(lowGain: 0.72, midGain: 1.05, highGain: 1.03, lowPassAlpha: 0.10, highPassAlpha: 0.09)
        case .bassBoost:
            return EQParams(lowGain: 1.3, midGain: 0.96, highGain: 0.95, lowPassAlpha: 0.13, highPassAlpha: 0.05)
        case .bassCut:
            return EQParams(lowGain: 0.76, midGain: 1.02, highGain: 1.02, lowPassAlpha: 0.11, highPassAlpha: 0.075)
        case .trebleBoost:
            return EQParams(lowGain: 0.95, midGain: 1.0, highGain: 1.28, lowPassAlpha: 0.13, highPassAlpha: 0.09)
        case .trebleCut:
            return EQParams(lowGain: 1.02, midGain: 1.0, highGain: 0.74, lowPassAlpha: 0.11, highPassAlpha: 0.05)
        }
    }
}

private struct EQParams {
    let lowGain: Float
    let midGain: Float
    let highGain: Float
    let lowPassAlpha: Float
    let highPassAlpha: Float
    var speechCleanupTuned: Bool = false
}

private struct ChannelState {
    var dcPrevInput: Float = 0
    var dcPrevOutput: Float = 0
    var hpPrevInput: Float = 0
    var hpPrevOutput: Float = 0
    var lpOutput: Float = 0
    var lowBand: Float = 0
    var highBand: Float = 0
    var highBandPrevInput: Float = 0
    var noiseFloor: Float = 0.0015
    var speechEnvelope: Float = 0
    var gateGain: Float = 1
    var humNotches: [BiquadNotchState] = []
}

private struct BiquadNotchState {
    private var b0: Float
    private var b1: Float
    private var b2: Float
    private var a1: Float
    private var a2: Float
    private var z1: Float = 0
    private var z2: Float = 0

    init(centerFrequency: Float, sampleRate: Float, q: Float) {
        let omega = 2 * Float.pi * centerFrequency / sampleRate
        let alpha = sin(omega) / (2 * q)
        let cosw = cos(omega)

        let rawB0: Float = 1
        let rawB1: Float = -2 * cosw
        let rawB2: Float = 1
        let rawA0: Float = 1 + alpha
        let rawA1: Float = -2 * cosw
        let rawA2: Float = 1 - alpha

        b0 = rawB0 / rawA0
        b1 = rawB1 / rawA0
        b2 = rawB2 / rawA0
        a1 = rawA1 / rawA0
        a2 = rawA2 / rawA0
    }

    mutating func process(_ input: Float) -> Float {
        let output = b0 * input + z1
        z1 = b1 * input - a1 * output + z2
        z2 = b2 * input - a2 * output
        return output
    }
}

private let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, tapStorageOut in
    guard let clientInfo else { return }
    tapStorageOut.pointee = clientInfo
}

private let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    let storage = MTAudioProcessingTapGetStorage(tap)
    Unmanaged<TapState>.fromOpaque(storage).release()
}

private let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, processingFormat in
    let storage = MTAudioProcessingTapGetStorage(tap)
    let state = Unmanaged<TapState>.fromOpaque(storage).takeUnretainedValue()
    state.prepare(processingFormat.pointee)
}

private let tapUnprepare: MTAudioProcessingTapUnprepareCallback = { _ in
}

private let tapProcess: MTAudioProcessingTapProcessCallback = { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
    var localFlags: MTAudioProcessingTapFlags = 0
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, &localFlags, nil, numberFramesOut)
    guard status == noErr else {
        flagsOut.pointee = localFlags
        return
    }

    let storage = MTAudioProcessingTapGetStorage(tap)
    let state = Unmanaged<TapState>.fromOpaque(storage).takeUnretainedValue()
    state.process(bufferList: bufferListInOut, frameCount: numberFramesOut.pointee)
    flagsOut.pointee = localFlags
}

extension VideoCuttingAudioProcessingEngine {
    enum AudioProcessingError: LocalizedError {
        case createTapFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case let .createTapFailed(status):
                return L10n.f("fmt.video.audio_chain_create_failed", status)
            }
        }
    }
}
