import Testing
@testable import PurrthroughCore

struct PeakMeterTests {
    @Test func reportsTheLoudestSampleOfEitherChannelSinceTheLastTake() {
        let meter = PeakMeter()
        let left: [Float] = [0.1, -0.4, 0.2]
        let right: [Float] = [0.3, 0, -0.6]
        meter.record(left: left, right: right, frames: 3)
        meter.record(left: [0.05], right: [0.05], frames: 1)
        #expect(meter.take() == 0.6)
        #expect(meter.take() == 0)
    }

    @Test func ignoresNaNButKeepsInfinity() {
        let meter = PeakMeter()
        meter.record(left: [.nan, 0.2], right: [0.1, .nan], frames: 2)
        #expect(meter.take() == 0.2)
        meter.record(left: [-.infinity], right: [0], frames: 1)
        #expect(meter.take() == .infinity)
    }

    @Test func concurrentRecordingAndTakingNeverLosesTheMaximum() async {
        let meter = PeakMeter()
        let rounds = 20_000
        // The writer records a rising series; every take must see a value no
        // larger than the latest recorded and the final take the maximum, unless
        // an earlier take already reported it.
        async let writer: Void = Task.detached {
            for index in 1...rounds {
                let sample = Float(index) / Float(rounds)
                meter.record(left: [sample], right: [0], frames: 1)
            }
        }.value
        var seenMaximum: Float = 0
        for _ in 0..<rounds {
            seenMaximum = max(seenMaximum, meter.take())
        }
        await writer
        seenMaximum = max(seenMaximum, meter.take())
        #expect(seenMaximum == 1)
    }
}
