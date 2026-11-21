import Testing
@testable import PurrthroughCore

struct PlaybackGainTests {
    @Test func scalesBothChannels() {
        let gain = PlaybackGain(1.5)
        var left: [Float] = [0.2, -0.4]
        var right: [Float] = [0.1, 0]
        gain.apply(left: &left, right: &right, frames: 2)
        #expect(left == [0.3, -0.6].map { Float($0) })
        #expect(right == [0.15, 0].map { Float($0) })
    }

    @Test func clampsToTheSupportedRange() {
        let gain = PlaybackGain(5)
        #expect(gain.value == PlaybackGain.maximum)
        gain.value = -1
        #expect(gain.value == 0)
        gain.value = .nan
        #expect(gain.value == 1)
    }
}
