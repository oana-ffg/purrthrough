import Testing
@testable import PurrthroughCore

struct StereoRingBufferTests {
    @Test func preservesChannelsAndOrderAcrossWraparound() {
        let ring = StereoRingBuffer(capacityFrames: 4)
        var outLeft = [Float](repeating: -1, count: 3)
        var outRight = [Float](repeating: -1, count: 3)
        for start in stride(from: 0, to: 30, by: 3) {
            let left: [Float] = (start..<start + 3).map(Float.init)
            let right = left.map { -$0 }
            #expect(ring.write(left: left, right: right, frames: 3) == 3)
            #expect(ring.read(left: &outLeft, right: &outRight, frames: 3) == 3)
            #expect(outLeft == left)
            #expect(outRight == right)
        }
    }

    @Test func dropsAndCountsInputWhenFull() {
        let ring = StereoRingBuffer(capacityFrames: 4)
        let samples: [Float] = [1, 2, 3, 4, 5, 6]
        #expect(ring.write(left: samples, right: samples, frames: 6) == 4)
        #expect(ring.totalDropped == 2)
        #expect(ring.availableFrames == 4)
    }

    @Test func padsUnderrunWithSilenceAndCountsIt() {
        let ring = StereoRingBuffer(capacityFrames: 8)
        let primer: [Float] = [1, 1]
        var scratch = [Float](repeating: 0, count: 2)
        var scratch2 = scratch
        ring.write(left: primer, right: primer, frames: 2)
        #expect(ring.read(left: &scratch, right: &scratch2, frames: 2) == 2)

        let samples: [Float] = [0.5, 0.25]
        ring.write(left: samples, right: samples, frames: 2)
        var left = [Float](repeating: 9, count: 5)
        var right = [Float](repeating: 9, count: 5)
        #expect(ring.read(left: &left, right: &right, frames: 5) == 2)
        #expect(left == [0.5, 0.25, 0, 0, 0])
        #expect(right == [0.5, 0.25, 0, 0, 0])
        #expect(ring.totalMissing == 3)
        #expect(ring.totalUnderruns == 1)
    }

    @Test func trimDiscardsOldestAudioOnNextRead() {
        let ring = StereoRingBuffer(capacityFrames: 16)
        let samples: [Float] = (0..<10).map(Float.init)
        ring.write(left: samples, right: samples, frames: 10)
        ring.requestTrim(toFill: 3)
        var left = [Float](repeating: 0, count: 3)
        var right = [Float](repeating: 0, count: 3)
        #expect(ring.read(left: &left, right: &right, frames: 3) == 3)
        #expect(left == [7, 8, 9])
        #expect(ring.availableFrames == 0)
    }
}

struct StereoRingBufferPrimingTests {
    @Test func waitsForPrimeLevelThenPlaysAndReprimesAfterUnderrun() {
        let ring = StereoRingBuffer(capacityFrames: 64)
        ring.setPrimeLevel(8)
        let samples = [Float](repeating: 1, count: 8)
        var left = [Float](repeating: 9, count: 4)
        var right = left
        ring.write(left: samples, right: samples, frames: 4)
        #expect(ring.read(left: &left, right: &right, frames: 4) == 0)
        #expect(left == [0, 0, 0, 0])
        #expect(ring.totalMissing == 0)
        ring.write(left: samples, right: samples, frames: 4)
        #expect(ring.read(left: &left, right: &right, frames: 4) == 4)
        #expect(ring.read(left: &left, right: &right, frames: 4) == 4)
        // Empty now: this read underruns and re-primes.
        #expect(ring.read(left: &left, right: &right, frames: 4) == 0)
        #expect(ring.totalUnderruns == 1)
        ring.write(left: samples, right: samples, frames: 4)
        #expect(ring.read(left: &left, right: &right, frames: 4) == 0)
    }

    @Test func tracksLargestChunks() {
        let ring = StereoRingBuffer(capacityFrames: 64)
        let samples = [Float](repeating: 1, count: 16)
        var out = [Float](repeating: 0, count: 32)
        var out2 = out
        ring.write(left: samples, right: samples, frames: 16)
        ring.write(left: samples, right: samples, frames: 3)
        ring.read(left: &out, right: &out2, frames: 32)
        #expect(ring.largestWrite == 16)
        #expect(ring.largestRead == 32)
    }
}

struct StereoRingBufferConcurrencyTests {
    /// A real producer thread and consumer thread, checking that every sample
    /// arrives exactly once and in order, with left and right kept together.
    @Test func producerAndConsumerThreadsKeepSamplesOrdered() async {
        let ring = StereoRingBuffer(capacityFrames: 512)
        ring.setPrimeLevel(0)
        let total = 2_000_000
        let producer = Task.detached {
            var next = 0
            var left = [Float](repeating: 0, count: 64)
            var right = left
            while next < total {
                let count = min(64, total - next)
                for index in 0..<count {
                    left[index] = Float(next + index)
                    right[index] = -Float(next + index)
                }
                next += ring.write(left: left, right: right, frames: count)
            }
        }
        let consumer = Task.detached { () -> Bool in
            var expected = 0
            var left = [Float](repeating: 0, count: 100)
            var right = left
            while expected < total {
                let count = ring.read(left: &left, right: &right, frames: min(100, total - expected))
                for index in 0..<count {
                    // Floats represent these integers exactly up to 2^24.
                    if left[index] != Float(expected) || right[index] != -Float(expected) { return false }
                    expected += 1
                }
            }
            return true
        }
        await producer.value
        #expect(await consumer.value)
    }
}
