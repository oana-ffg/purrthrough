import Testing
@testable import PurrthroughCore

struct SilenceGateTests {
    @Test func startsReleasedSoAQuietSourceNeverGrabsTheOutput() {
        let gate = SilenceGate(releaseAfter: 30)
        #expect(!gate.holdsOutput(at: 1000))
    }

    @Test func holdsFromTheFirstSoundUntilTheSilenceLastsLongEnough() {
        var gate = SilenceGate(releaseAfter: 30)
        gate.record(peak: 0.5, at: 100)
        #expect(gate.holdsOutput(at: 100))
        gate.record(peak: 0, at: 129.9)
        #expect(gate.holdsOutput(at: 129.9))
        gate.record(peak: 0, at: 130)
        #expect(!gate.holdsOutput(at: 130))
    }

    @Test func soundDuringTheCountdownRestartsIt() {
        var gate = SilenceGate(releaseAfter: 30)
        gate.record(peak: 0.5, at: 0)
        gate.record(peak: 0.5, at: 20)
        #expect(gate.holdsOutput(at: 45))
        #expect(!gate.holdsOutput(at: 50))
    }

    @Test func noiseBelowTheThresholdCountsAsSilence() {
        var gate = SilenceGate(releaseAfter: 30)
        // −67 dBFS: the measured noise peak of a USB line input with its source silent.
        let noise: Float = 0.000_45
        #expect(noise < SilenceGate.defaultThreshold)
        gate.record(peak: noise, at: 10)
        #expect(!gate.holdsOutput(at: 10))
        gate.record(peak: SilenceGate.defaultThreshold, at: 11)
        #expect(gate.holdsOutput(at: 11))
    }

    @Test func forgettingSoundReleasesAtOnce() {
        var gate = SilenceGate(releaseAfter: 30)
        gate.record(peak: 0.5, at: 100)
        gate.forgetSound()
        #expect(!gate.holdsOutput(at: 101))
    }

    @Test func neverReleasingHoldsEvenBeforeAnySound() {
        var gate = SilenceGate(releaseAfter: nil)
        #expect(gate.holdsOutput(at: 0))
        gate.releaseAfter = 10
        #expect(!gate.holdsOutput(at: 0))
        gate.releaseAfter = nil
        #expect(gate.holdsOutput(at: 1_000_000))
    }
}
