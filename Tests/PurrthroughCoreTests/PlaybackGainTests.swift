import Testing
@testable import PurrthroughCore

struct PlaybackGainTests {
    @Test func boostsQuietAudioLinearly() {
        let gain = PlaybackGain(3)
        var left: [Float] = [0.1, -0.2]
        var right: [Float] = [0.05, 0]
        gain.apply(left: &left, right: &right, frames: 2)
        #expect(abs(left[0] - 0.3) < 1e-6 && abs(left[1] + 0.6) < 1e-6)
        #expect(abs(right[0] - 0.15) < 1e-6 && right[1] == 0)
    }

    @Test func loudBoostedPeaksNeverExceedFullScale() {
        let gain = PlaybackGain(PlaybackGain.maximum)
        var left: [Float] = [0.9, -1, 0.3]
        var right: [Float] = [0.5, -0.25, 1]
        gain.apply(left: &left, right: &right, frames: 3)
        for sample in left + right {
            #expect(abs(sample) <= 1)
        }
        // Order is preserved: louder input stays louder after limiting.
        #expect(right[0] > right[1].magnitude)
    }

    @Test func attenuationIsNotLimited() {
        let gain = PlaybackGain(0.5)
        var left: [Float] = [1]
        var right: [Float] = [-1]
        gain.apply(left: &left, right: &right, frames: 1)
        #expect(left == [0.5] && right == [-0.5])
    }

    @Test func clampsToTheSupportedRange() {
        let gain = PlaybackGain(10)
        #expect(gain.value == PlaybackGain.maximum)
        gain.value = -1
        #expect(gain.value == 0)
        gain.value = .nan
        #expect(gain.value == 1)
    }
}
