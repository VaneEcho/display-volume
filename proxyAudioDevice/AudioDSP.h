#pragma once

#include <algorithm>
#include <cstddef>
#include <cmath>

namespace ProxyAudioDSP {
inline float gain(float scalar, bool mute, float minDB, float maxDB) {
    if (mute || !std::isfinite(scalar) || scalar <= 0) return 0;
    scalar = std::min(1.0f, scalar);
    return std::pow(10.0f, (minDB + scalar * scalar * (maxDB - minDB)) / 20.0f);
}

// Channel numbers are global and zero based, including for planar buffers.
inline void mixStereo(const float *input, size_t inputFrames, float *output,
                      size_t outputSamples, size_t channels, size_t channelOffset,
                      size_t left, size_t right, float previousL, float previousR,
                      float targetL, float targetR, size_t rampFrames) {
    if (!input || !output || !channels) return;
    const size_t frames = std::min(inputFrames, outputSamples / channels);
    for (size_t channel = 0; channel < channels; ++channel) {
        const size_t global = channelOffset + channel;
        if (global != left && global != right) continue;
        const bool isLeft = global == left;
        const float previous = isLeft ? previousL : previousR;
        const float target = isLeft ? targetL : targetR;
        for (size_t frame = 0; frame < frames; ++frame) {
            const float progress = rampFrames ? std::min(1.0f, float(frame + 1) / rampFrames) : 1.0f;
            output[frame * channels + channel] += input[frame * 2 + (isLeft ? 0 : 1)]
                * (previous + (target - previous) * progress);
        }
    }
}
}
