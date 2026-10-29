#import "../../SpatialRelay/Audio/AudioCaptureBridge.mm"
#include <cassert>
#include <iostream>
#include <thread>

int main() {
    @autoreleasepool {
        // Exercise the actual implementation with synthetic data; no HAL capture.
        CaptureStorage state(16);
        float source[40];
        for (int i = 0; i < 40; ++i) source[i] = float(i) / 32;
        state.writeInterleaved(source, 12);
        float output[40] = {};
        assert(state.readInterleaved(output, 10) == 10);
        assert(std::memcmp(source, output, 20 * sizeof(float)) == 0);
        state.writeInterleaved(source + 24, 8);
        assert(state.readInterleaved(output, 16) == 10);
        assert(std::memcmp(source + 20, output, 20 * sizeof(float)) == 0);
        state.reset();
        state.writeInterleaved(source, 20);
        assert(state.available() == 16 && state.droppedFrames == 4);
        state.reset();

        struct StereoPlanarBuffers { UInt32 count; AudioBuffer buffers[2]; } planar;
        float left[] = {0.25, 0.5, -0.75};
        float right[] = {-0.5, 1, 0.125};
        planar.count = 2;
        planar.buffers[0] = {1, sizeof(left), left};
        planar.buffers[1] = {1, sizeof(right), right};
        state.nonInterleaved = true;
        captureIOProc(0, nullptr, reinterpret_cast<AudioBufferList *>(&planar), nullptr, nullptr, nullptr, &state);
        assert(state.readInterleaved(output, 3) == 3);
        for (int i = 0; i < 3; ++i) { assert(output[2*i] == left[i]); assert(output[2*i+1] == right[i]); }
        planar.buffers[1].mDataByteSize -= 1;
        captureIOProc(0, nullptr, reinterpret_cast<AudioBufferList *>(&planar), nullptr, nullptr, nullptr, &state);
        assert(state.formatMismatches == 1 && state.available() == 0);
        std::cout << "PASS: stereo byte preservation, wraparound, bounded overflow, planar callback, malformed layout rejection\n";

        CaptureStorage concurrent(1024);
        constexpr UInt64 total = 2'000'000;
        std::thread producer([&] {
            for (UInt64 i = 0; i < total; ++i) {
                while (concurrent.available() == concurrent.capacityFrames) std::this_thread::yield();
                float frame[] = {float(i), -float(i)};
                concurrent.writeInterleaved(frame, 1);
            }
        });
        for (UInt64 i = 0; i < total; ++i) {
            float frame[2];
            while (!concurrent.readInterleaved(frame, 1)) std::this_thread::yield();
            assert(frame[0] == float(i) && frame[1] == -float(i));
        }
        producer.join();
        assert(concurrent.droppedFrames == 0 && concurrent.available() == 0);
        std::cout << "PASS: 2,000,000 frames through concurrent producer/consumer in order\n";

        SRAudioCaptureBridge *bridge = [[SRAudioCaptureBridge alloc] init];
        NSData *data = [NSData dataWithBytes:source length:sizeof(source)];
        [bridge debugEnqueueInterleavedFloatData:data];
        assert(bridge.availableFrameCount == 20);
        SRPCMChunk *chunk = [bridge dequeueChunkWithMaximumFrameCount:20];
        assert(chunk.frameCount == 20 && [chunk.data isEqualToData:data]);
        assert(bridge.peakLevel == 1 && bridge.peakLevel == 0);
        std::cout << "PASS: Objective-C bridge dequeue and peak consumption\n";
        [bridge debugEnqueueInterleavedFloatData:data];
        assert([bridge discardFramesKeepingLatest:3] == 17);
        assert(bridge.discardedFrameCount == 17 && bridge.availableFrameCount == 3);
        chunk = [bridge dequeueChunkWithMaximumFrameCount:20];
        assert(chunk.frameCount == 3);
        assert(std::memcmp(chunk.data.bytes, source + 34, 6*sizeof(float)) == 0);
        assert([bridge discardFramesKeepingLatest:30] == 0);
        [bridge reset];
        float silent[20] = {};
        [bridge debugEnqueueInterleavedFloatData:[NSData dataWithBytes:silent length:sizeof(silent)]];
        assert(bridge.signalFrameCount == 0 && bridge.discardedFrameCount == 0);
        [bridge debugEnqueueInterleavedFloatData:data];
        assert(bridge.signalFrameCount == 20);
        std::cout << "PASS: newest PCM retained after discard, reset accounting, independent silence detection\n";

        CaptureStorage trimming(1024);
        constexpr UInt64 trimmingTotal = 2'000'000;
        std::atomic<bool> done { false };
        std::thread trimmingProducer([&] {
            for (UInt64 i = 0; i < trimmingTotal; ++i) {
                while (trimming.available() == trimming.capacityFrames) std::this_thread::yield();
                float frame[] = {float(i), -float(i)};
                trimming.writeInterleaved(frame, 1);
            }
            done.store(true, std::memory_order_release);
        });
        int64_t last = -1;
        UInt64 consumed = 0;
        UInt64 iterations = 0;
        while (!done.load(std::memory_order_acquire) || trimming.available() > 0) {
            if (++iterations % 137 == 0) trimming.discardKeepingLatest(16);
            float frame[2];
            if (!trimming.readInterleaved(frame, 1)) { std::this_thread::yield(); continue; }
            assert(frame[0] > float(last) && frame[1] == -frame[0]);
            last = static_cast<int64_t>(frame[0]);
            ++consumed;
        }
        trimmingProducer.join();
        assert(last == trimmingTotal-1);
        assert(consumed + trimming.discardedFrames.load() == trimmingTotal);
        assert(trimming.droppedFrames == 0);
        std::cout << "PASS: concurrent capture + latency trimming, monotonic samples and exact accounting\n";
    }
}
