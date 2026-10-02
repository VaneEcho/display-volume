#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_output=$(mktemp -d "${TMPDIR:-/tmp}/display-volume-tests.XXXXXX")
trap 'rm -rf "$test_output"' EXIT
xcrun clang++ -std=c++17 -fsanitize=address,undefined -g \
  tests/audio_tests.cpp proxyAudioDevice/AudioRingBuffer.cpp \
  -framework CoreServices -o "$test_output/audio-tests"
"$test_output/audio-tests"
xcrun clang++ -std=c++17 -fblocks -DDEBUG=0 -Wno-deprecated-declarations \
  -fsanitize=address,undefined -g -Ishared -IproxyAudioDevice -IproxyAudioDevice/PublicUtility \
  tests/driver_lifecycle_tests.cpp proxyAudioDevice/ProxyAudioDevice.cpp \
  proxyAudioDevice/AudioRingBuffer.cpp shared/AudioDevice.cpp proxyAudioDevice/utilities.cpp \
  proxyAudioDevice/PublicUtility/*.cpp -framework CoreAudio -framework CoreServices \
  -framework IOKit -o "$test_output/lifecycle-tests"
"$test_output/lifecycle-tests"
