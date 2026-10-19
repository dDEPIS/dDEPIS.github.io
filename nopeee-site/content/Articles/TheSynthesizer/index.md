---
title: "The Synthesizer"
summary: " "
categories: ["Project"]
tags: ["project", "C++", "JUCE", "Audio Programming", "DSP", "Synthesizer"]
#externalUrl: ""
#showSummary: true
date: 2026-05-25
draft: false
---

This project is a polyphonic, dual-engine virtual analog synthesizer built using C++ and the JUCE framework.

Rather than relying purely on standard boilerplate components, the synth implements custom band-limited oscillators, dynamic cross-engine FM routing, a legato interceptor, a lock-free modulation matrix with animated UI controls, and a modular effects rack.

## 1. Dual-Engine Architecture & Anti-Aliased Oscillators

The core sound generation is driven by two independent sound engines, each packing three oscillators and a dedicated colored noise generator. Naive digital waveforms introduce harsh aliasing artifacts due to sharp discontinuities reflecting across the Nyquist frequency. To solve this, the `AnalogOscillator` class implements band-limiting algorithms directly into the per-sample phase accumulation.

```cpp
float AnalogOscillator::polyBlep(float t, float dt)
{
    if (t < dt) {
        t /= dt;
        return t + t - t * t - 1.0f;
    }
    else if (t > 1.0f - dt) {
        t = (t - 1.0f) / dt;
        return t * t + t + t + 1.0f;
    }
    return 0.0f;
}
```

While PolyBLEP (Polynomial Bandlimited Step) handles the zero-order step discontinuities in Saw and Square waves, the Triangle wave presents a different challenge: continuous amplitude but discontinuous derivative (slope changes). For this, I used PolyBLAMP (Polynomial Bandlimited Ramp) at the waveform's peak and trough to suppress mirror harmonics:

```cpp
// Triangle wave generation with PolyBLAMP smoothing
if (effectivePhase < width) out = -1.0f + 2.0f * (effectivePhase / width);
else                        out = 1.0f - 2.0f * ((effectivePhase - width) / (1.0f - width));

float slopeChange1 = (2.0f / width) - (-2.0f / (1.0f - width));
out -= polyBlamp(effectivePhase, phaseDelta) * slopeChange1 * phaseDelta;

float slopeChange2 = (-2.0f / (1.0f - width)) - (2.0f / width);
float phase2 = effectivePhase + 1.0f - width;
if (phase2 >= 1.0f) phase2 -= 1.0f;
out -= polyBlamp(phase2, phaseDelta) * slopeChange2 * phaseDelta;
```

Each engine also includes a continuous noise generator. Instead of hard-switching between noise types, a single color parameter interpolates between a one-pole low-pass filtered brown noise, white noise, and a high-pass filtered blue noise:

```cpp
float white = (random.nextFloat() * 2.0f) - 1.0f;
brown = (0.99f * brown) + (0.01f * white);       // One-pole low-pass
float blueSample = (white - lastWhite) * 0.5f;   // High-pass differentiator
lastWhite = white;

// Crossfade across the spectrum based on color parameter
if (color < 0.5f) out = (brown * 3.5f * (1.0f - color * 2.0f)) + (white * color * 2.0f);
else              out = (white * (1.0f - (color - 0.5f) * 2.0f)) + (blueSample * (color - 0.5f) * 2.0f);
```

## 2. Dynamic Frequency Modulation & Cross-Engine Routing

The synth provides deep FM flexibility without phase-delay latency. Within an engine, Oscillator 3 runs first on every sample to act as a zero-delay modulator for Oscillators 1 and 2. Furthermore, the architecture supports true cross-engine FM, allowing Engine 1 to modulate Engine 2 and vice-versa:

```cpp
// Engine::processSample()
float osc3Out = oscillators[2].processSample(params.oscs[2].wave, params.oscs[2].width, 0.0f);
osc3OutForExternal = osc3Out;

// Combine local noise and osc3, then blend with external cross-engine signal
float localMod = modNoise * (1.0f - fmSourceMix) + osc3Out * fmSourceMix;
float modulator = localMod * (1.0f - fmEngineMix) + crossEngineMod * fmEngineMix;

// Modulate carrier phases
for (int i = 0; i < 2; ++i) {
    float phaseOffset = modulator * oscFmAmts[i] * 8.0f;
    out += oscillators[i].processSample(params.oscs[i].wave, params.oscs[i].width, phaseOffset)
           * oscLevelGains[i];
}
```

All parameter changes (levels, FM depths, and cross-engine mixes) are smoothed per sample using `juce::LinearSmoothedValue` to prevent parameter-stepping zipper noise during rapid modulation or automation sweeps.

## 3. Legato Glide & Custom Polyphony

JUCE's base `Synthesiser` manages standard voice allocation well, but its default voice stealing and `noteOff` handling do not support monophonic synthesizer conventions like legato fallback.

To achieve smooth monophonic performance, `CustomSynth` intercepts note events and maintains an active stack of physically pressed keys (`heldNotes`). If a note is released while earlier notes are still held, the engine suppresses voice termination and instead glides pitch back to the previous note:

```cpp
void CustomSynth::noteOff(const int midiChannel, const int midiNoteNumber, const float velocity, bool allowTailOff)
{
    heldNotes.removeAllInstancesOf(midiNoteNumber);

    if (isLegato && voices[0] != nullptr)
    {
        if (!heldNotes.isEmpty()) {
            // Fall back to previous held note with portamento glide
            int lastHeldNote = heldNotes.getLast();
            if (auto* currentVoice = dynamic_cast<SynthVoice*>(voices[0]))
                currentVoice->setLegatoGlide(lastHeldNote);
            return;
        }
        else {
            int originalNote = voices[0]->getCurrentlyPlayingNote();
            juce::Synthesiser::noteOff(midiChannel, originalNote, velocity, allowTailOff);
            return;
        }
    }
    juce::Synthesiser::noteOff(midiChannel, midiNoteNumber, velocity, allowTailOff);
}
```

Inside `SynthVoice`, pitch glides run via an exponential/linear smoother (`smoothedHz`), allowing either legato-only portamento or constant glide across all played notes.

## 4. Modulation Matrix & Host-Locked LFOs

The synth includes a central routing matrix (`ModMatrix`) capable of dispatching signals from three multi-waveform LFOs, two dedicated modulation envelopes, and the master amp envelope.

To maintain real-time safety, modulator values are updated via `std::atomic<float>` on the audio thread. The matrix calculates parameter offsets in normalized space before mapping back to target parameter ranges, preventing out-of-bounds DSP explosions:

```cpp
float ModMatrix::getModulatedValue(const juce::String& paramID, float baseValue,
                                   const juce::NormalisableRange<float>& range) const
{
    float modAmount = 0.0f;
    {
        const juce::SpinLock::ScopedLockType lock(routesLock);
        for (const auto& route : routes)
            if (route.destParamID == paramID)
                modAmount += sourceValues[(size_t)route.sourceIndex].load(std::memory_order_relaxed) * route.depth;
    }

    float normalised = range.convertTo0to1(baseValue);
    normalised = juce::jlimit(0.0f, 1.0f, normalised + modAmount);
    return range.convertFrom0to1(normalised);
}
```

The LFO class offers both free-running Hz and tempo-synced musical divisions. When synced, the phase locks directly to host playhead positions using the DAW's PPQ (Pulses Per Quarter note) position:

```cpp
if (syncMode == SyncMode::TempoSynced && hostIsPlaying) {
    const double cyclesPerQuarter = 1.0 / syncDivision;
    phase = (float)std::fmod(currentPpq * cyclesPerQuarter + phaseOffset, 1.0);
    if (phase < 0.0f) phase += 1.0f;
    currentPpq += (currentBpm / 60.0) / sampleRate;
} else {
    phase += (freeRateHz) / (float)sampleRate;
    while (phase >= 1.0f) phase -= 1.0f;
}
```

In addition to Sine, Triangle, Saw, and Square shapes, the LFO features Sample & Hold and smooth random modes driven by one-pole low-pass filtering and symmetry controls.

## 5. UI Architecture: Modulatable Sliders & Interactive Envelopes

To make modulation intuitive, I avoided clunky static routing tables. Instead, knobs provide visual feedback directly.

The `ModulatableSlider` overrides JUCE's `paint()` method to draw color-coded dynamic arcs representing the real-time modulation range and the current modulated value around the knob circumference. Right-clicking any knob summons a context menu to quickly bind or unbind sources.

```cpp
// Inside ModulatableSlider::drawModulationOverlay()
float baseAngle = rotaryStartAngle + baseNormalised * (rotaryEndAngle - rotaryStartAngle);
float modAngle  = rotaryStartAngle + modNormalised * (rotaryEndAngle - rotaryStartAngle);

juce::Path arc;
arc.addCentredArc(centre.x, centre.y, radius, radius, 0.0f,
                  juce::jmin(baseAngle, modAngle), juce::jmax(baseAngle, modAngle), true);

g.setColour(getSourceColour(route.sourceIndex).withAlpha(0.85f));
g.strokePath(arc, juce::PathStrokeType(2.5f, juce::PathStrokeType::curved, juce::PathStrokeType::rounded));
radius += 4.0f; // Stack concentric rings for multi-source modulation
```

The `InteractiveEnvelopeDisplay` renders ADSR stages on a logarithmic time curve, providing draggable handles for Attack, Decay, Sustain, and Release. It also polls voice atomic variables to display an animated glowing playhead tracking the active envelope phase in real time:

```cpp
// Compute visual playhead along the ADSR path
if (state == 1) { // Attack, Decay, or Sustain
    if (time <= attack) {
        float progress = time / attack;
        dotX = left + (attackX - left) * progress;
        dotY = bottom + (attackY - bottom) * progress;
    } else if (time <= attack + decay) {
        float progress = (time - attack) / decay;
        dotX = attackX + (decayX - attackX) * progress;
        dotY = attackY + (sustainY - attackY) * progress;
    }
}
```

## 6. Dual Filters & Real-Time Bode Plot Visualizer

Sound shaping is handled by two independent State Variable TPT (Topology-Preserving Transform) filters capable of Lowpass, Highpass, and Bandpass response. The filter section provides a continuous blend between parallel routing (both engines feeding both filters) and serial routing (Filter 1 feeding Filter 2).

```cpp
// Series/Parallel filter routing blend inside SynthVoice::renderNextBlock()
float f1Output = f1Active ? filter1.processSample(0, parallelF1In) : parallelF1In;
float f2Input  = parallelF2In + (f1Output * f1Vol) * routingMix;
float f2Output = f2Active ? filter2.processSample(0, f2Input) : f2Input;
```

To eliminate guesswork during sound design, the `FilterComponent` computes the exact mathematical frequency response of the active filter state and paints a normalized Bode plot at 30 FPS:

```cpp
// Evaluate magnitude response across frequency bins
for (int i = 0; i < (int)w; ++i) {
    float freq = 20.0f * std::pow(20000.0f / 20.0f, (float)i / w);
    float m = coeffs->getMagnitudeForFrequency(freq, sampleRate);
    mags.push_back(m);
    if (m > maxMag) maxMag = m;
}

// Draw magnitude mapped to decibels (-24dB to +12dB)
float normFactor = (maxMag > 1.0f) ? (1.0f / maxMag) : 1.0f;
for (int i = 0; i < mags.size(); ++i) {
    float db = juce::Decibels::gainToDecibels(mags[i] * normFactor, -24.0f);
    float py = juce::jlimit(y, bottom, juce::jmap(db, -24.0f, 12.0f, bottom, y));
    if (i == 0) p.startNewSubPath(x + i, py);
    else        p.lineTo(x + i, py);
}
```

## 7. Modular FX Rack: Series and Aux Chains

The post-processing section consists of a modular rack structured into a 3-slot Series chain and a 3-slot Aux chain with dedicated send, receive, and return buses. Each slot dynamically hosts one of six effects: Delay, Reverb, Distortion, Chorus, Phaser, or Bitcrusher.

The delay effect (`Delay.h`) implements a ring buffer with feedback saturation (`std::tanh`) to keep feedback swells musical, alongside dual IIR low-pass and high-pass filters and a ping-pong mode:

```cpp
// Ping-pong delay with feedback saturation
if (isPingPong) {
    float monoInput = (inputL[i] + inputR[i]) * 0.5f;
    dlineInputL = std::tanh(monoInput + (delayedR * feedback));
    dlineInputR = std::tanh(delayedL * feedback);
} else {
    dlineInputL = std::tanh(inputL[i] + (delayedL * feedback));
    dlineInputR = std::tanh(inputR[i] + (delayedR * feedback));
}
```

For digital character, the `BitcrusherFx` reduces word-length resolution and decimates the sample rate using sample-and-hold step quantization:

```cpp
// Decimation and bit quantization
s.counter += 1.0f;
if (s.counter >= down) {
    s.held = std::round(data[i] * levels) * invLevels;
    s.counter -= down;
}
data[i] = s.held * out;
```

Because each effect inherits from `FxProcessorBase` and interfaces with the `ModMatrix`, any parameter—including delay times, chorus depths, and bit crushing—can be modulated using the synth's internal LFOs and envelopes.

## 8. Real-Time Oscilloscope & Spectrum Analyzer

For continuous audio monitoring, the master output feeds two visual components: a 2048-point FFT spectrum analyzer and an oscilloscope.

An oscilloscope can easily suffer from visual jitter if redrawn on arbitrary buffer intervals. To stabilize the waveform, the processor uses an arming threshold and a trigger threshold before recording into the display FIFO:

```cpp
// Oscilloscope trigger stabilization
if (!isScopeFilling) {
    if (!isScopeArmed && sample < scopeArmThreshold) {
        isScopeArmed = true; // Armed on negative slope
    }
    else if (isScopeArmed && sample >= scopeTriggerThreshold && lastScopeSample < scopeTriggerThreshold) {
        isScopeFilling = true; // Triggered on positive zero-crossing
        scopeIndex = 0;
        isScopeArmed = false;
    }
}
```

The spectrum analyzer processes incoming samples through a Hann window before running forward transforms using `juce::dsp::FFT`, drawing the frequency response with logarithmic scaling on the message thread.

## 9. State Persistence & Preset Management

Managing complex state trees requires serializing parameter layouts alongside dynamic modulation routings. The `PresetManager` serializes the plugin's `AudioProcessorValueTreeState` while injecting custom child trees storing the dynamic matrix mappings:

```cpp
// PresetManager::savePreset()
auto stateTree = apvts.copyState();
stateTree.appendChild(modMatrix.saveToValueTree(), nullptr);

if (auto xml = stateTree.createXml()) {
    currentPresetName = presetName;
    return xml->writeTo(file);
}
```

When loading presets or restoring DAW project sessions, the tree extracts the routing data, updates the `ModMatrix`, strips the child node, and hands the clean tree back to the APVTS.

By combining band-limited DSP foundations, a responsive modulation architecture, and custom GUI visualizers, the synthesizer delivers a modern virtual analog experience with deep sound design flexibility and zero-latency feedback.