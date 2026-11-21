import Testing
@testable import PurrthroughCore

struct DriftControllerTests {
    @Test func holdsNominalRateAtTarget() {
        var controller = DriftController(targetFrames: 1000, maximumFrames: 5000)
        #expect(controller.update(fillFrames: 1000) == .init(rate: 1, trimToFrames: nil))
    }

    @Test func speedsUpWhenBacklogGrowsAndSlowsWhenStarved() {
        var fast = DriftController(targetFrames: 1000, maximumFrames: 5000)
        #expect(fast.update(fillFrames: 1500).rate > 1)
        var slow = DriftController(targetFrames: 1000, maximumFrames: 5000)
        #expect(slow.update(fillFrames: 200).rate < 1)
    }

    @Test func correctionIsCappedBelowAudiblePitchChange() {
        var controller = DriftController(targetFrames: 1000, maximumFrames: 5000, maximumDeviation: 0.005)
        #expect(controller.update(fillFrames: 4900).rate == 1.005)
        controller.reset()
        #expect(controller.update(fillFrames: 0).rate == 0.995)
    }

    @Test func cutsExcessLatencyImmediately() {
        var controller = DriftController(targetFrames: 1000, maximumFrames: 5000)
        #expect(controller.update(fillFrames: 9000) == .init(rate: 1, trimToFrames: 1000))
        // Smoothing restarts from the target, not from the stale backlog.
        #expect(controller.update(fillFrames: 1000).rate == 1)
    }

    @Test func steadyDriftConvergesToSmallBoundedError() {
        // Output consumes 300 ppm slower than input produces.
        var controller = DriftController(targetFrames: 2400, maximumFrames: 24000)
        var fill = 2400.0
        let producedPerTick = 4800.0
        for _ in 0..<20_000 {
            let decision = controller.update(fillFrames: Int(fill))
            fill += producedPerTick - producedPerTick * (1 - 0.0003) * decision.rate
        }
        #expect(abs(fill - 2400) < 2400 * 0.1)
    }
}
