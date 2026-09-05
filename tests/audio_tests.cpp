#include "../proxyAudioDevice/AudioDSP.h"
#include "../proxyAudioDevice/AudioRingBuffer.h"
#include <cassert>
#include <cmath>
#include <limits>
#include <iostream>

int main() {
    using namespace ProxyAudioDSP;
    assert(gain(0, false, -25, 0) == 0);
    assert(gain(1, false, -25, 0) == 1);
    assert(gain(1, true, -25, 0) == 0);
    assert(gain(std::numeric_limits<float>::quiet_NaN(), false, -25, 0) == 0);
    assert(std::abs(20 * std::log10(gain(.5f, false, -25, 0)) + 18.75f) < .0001f);
    float input[] = {1, 2, 3, 4};
    float interleaved[4] = {}, left[2] = {}, right[2] = {};
    mixStereo(input, 2, interleaved, 4, 2, 0, 0, 1, 1, 1, 1, 1, 0);
    mixStereo(input, 2, left, 2, 1, 0, 0, 1, 1, 1, 1, 1, 0);
    mixStereo(input, 2, right, 2, 1, 1, 0, 1, 1, 1, 1, 1, 0);
    for (int i = 0; i < 2; ++i) {
        assert(interleaved[2*i] == left[i]);
        assert(interleaved[2*i+1] == right[i]);
    }
    assert(right[0] == 2 && right[1] == 4);
    float surround[12] = {};
    mixStereo(input, 2, surround, 12, 6, 0, 4, 5, 1, 1, 1, 1, 0);
    assert(surround[4] == 1 && surround[5] == 2 && surround[10] == 3 && surround[11] == 4);
    assert(surround[0] == 0 && surround[6] == 0);
    float bounded[6] = {0, 0, 0, 0, 99, 99};
    mixStereo(input, 2, bounded, 6, 2, 0, 0, 1, 1, 1, 1, 1, 0);
    assert(bounded[4] == 99 && bounded[5] == 99);
    float ramp[4] = {};
    mixStereo(input, 2, ramp, 4, 2, 0, 0, 1, 0, 0, 1, 1, 2);
    assert(ramp[0] == .5f && ramp[1] == 1 && ramp[2] == 3 && ramp[3] == 4);
    mixStereo(input, 2, nullptr, 4, 2, 0, 0, 1, 1, 1, 1, 1, 0);
    AudioRingBuffer ring(2 * sizeof(float), 4);
    assert(ring.Store((const Byte *)input, 2, 10));
    float fetched[4] = {};
    assert(!ring.Fetch((Byte *)fetched, 2, 10));
    for (int i = 0; i < 4; ++i) assert(fetched[i] == input[i]);
    assert(ring.Store((const Byte *)input, 2, 12));
    assert(ring.Store((const Byte *)input, 2, 14));
    assert(!ring.Fetch((Byte *)fetched, 2, 14));
    for (int i = 0; i < 4; ++i) assert(fetched[i] == input[i]);
    ring.Fetch((Byte *)fetched, 2, 100);
    for (float value : fetched) assert(value == 0);
    std::cout << "Audio regression tests passed\n";
}
