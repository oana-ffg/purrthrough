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
        let samples: [Float] = [0.5, 0.25]
        ring.write(left: samples, right: samples, frames: 2)
        var left = [Float](repeating: 9, count: 5)
        var right = [Float](repeating: 9, count: 5)
        #expect(ring.read(left: &left, right: &right, frames: 5) == 2)
        #expect(left == [0.5, 0.25, 0, 0, 0])
        #expect(right == [0.5, 0.25, 0, 0, 0])
        #expect(ring.totalMissing == 3)
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
