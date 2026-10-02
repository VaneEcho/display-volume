#include "../proxyAudioDevice/ProxyAudioDevice.h"
#include "../proxyAudioDevice/AudioRingBuffer.h"
#include <cstdio>

// Exercise the actual driver lifecycle without loading a HAL plug-in or touching devices.
int main() {
    auto ref = static_cast<AudioServerPlugInDriverRef>(ProxyAudio_Create(nullptr, kAudioServerPlugInTypeUUID));
    ProxyAudioDevice device;
    device.audioOutputQueue = dispatch_queue_create("display-volume.lifecycle-test", DISPATCH_QUEUE_SERIAL);
    device.inputBuffer = new AudioRingBuffer(2 * sizeof(float), 4096);
    int failures = 0;
    auto check = [&](bool condition, const char *message) {
        if (!condition) { std::fprintf(stderr, "FAIL: %s\n", message); ++failures; }
    };
    check(device.StartIO(ref, kObjectID_Device, 10) == noErr, "first client starts");
    device.lastInputFrameTime = 512;
    device.lastInputBufferFrameSize = 512;
    device.inputOutputSampleDelta = 1234;
    check(device.StartIO(ref, kObjectID_Device, 20) == noErr, "second client starts");
    check(device.lastInputFrameTime == 512 && device.inputOutputSampleDelta == 1234,
          "another client starting must not discard the playing stream");
    device.lastInputFrameTime = 512;
    device.lastInputBufferFrameSize = 512;
    check(device.StopIO(ref, kObjectID_Device, 20) == noErr, "second client stops");
    check(device.gDevice_IOIsRunning == 1 && device.inputIOIsActive,
          "first client remains active");
    check(device.inputFinalFrameTime == -1,
          "one client stopping must not permanently silence the remaining client");
    // Keep the first client writing beyond the stopped client's last frame.
    // Verify actual output samples, not only the lifecycle counters.
    float input[1024], output[1024] = {};
    for (float &sample : input) sample = .25f;
    device.inputBuffer->Store(reinterpret_cast<const Byte *>(input), 512, 4096);
    device.lastInputFrameTime = 4608;
    device.lastInputBufferFrameSize = 512;
    device.inputOutputSampleDelta = 0;
    device.workBuffer = new Byte[sizeof(input)];
    device.outputDevice.sampleRate = device.gDevice_SampleRate;
    device.outputDevice.bufferFrameSize = 512;
    device.gVolume_Output_L_Value = device.gVolume_Output_R_Value = 1;
    device.previousGainL = device.previousGainR = 1;
    AudioTimeStamp timestamp = {};
    timestamp.mSampleTime = 4096;
    timestamp.mRateScalar = 1;
    timestamp.mFlags = kAudioTimeStampSampleTimeValid | kAudioTimeStampRateScalarValid;
    AudioBufferList buffers = {};
    buffers.mNumberBuffers = 1;
    buffers.mBuffers[0] = {2, sizeof(output), output};
    device.outputDeviceIOProc(0, &timestamp, nullptr, &timestamp, &buffers, &timestamp);
    check(output[0] == .25f && output[1023] == .25f,
          "remaining client's output must still contain audio after another client stops");
    check(device.StopIO(ref, kObjectID_Device, 10) == noErr, "last client stops");
    check(!device.inputIOIsActive && device.inputFinalFrameTime == 5120,
          "only the last client closes the stream");
    check(device.StartIO(ref, kObjectID_Device, 30) == noErr, "playback restarts");
    check(device.inputFinalFrameTime == -1 && device.lastInputFrameTime == -1,
          "restart clears the old timeline");
    check(device.StopIO(ref, kObjectID_Device, 30) == noErr, "final stop succeeds");
    dispatch_sync(device.audioOutputQueue, ^{});
    dispatch_release(device.audioOutputQueue);
    delete device.inputBuffer;
    delete[] device.workBuffer;
    if (!failures) std::puts("Driver lifecycle regression tests passed");
    return failures ? 1 : 0;
}
