import Testing
@testable import PurrthroughCore

/// Simulates a USB input delivering small chunks and a Bluetooth-like output
/// pulling large ones, with the controller running at its real cadence.
struct BurstyDevicesTests {
    private func run(inputChunk: Int, outputChunk: Int, outputPPMSlow: Double, seconds: Int) -> StereoRingBuffer {
        let rate = 48_000.0
        let ring = StereoRingBuffer(capacityFrames: Int(rate))
        var plan = LatencyPlan(sampleRate: rate, largestRead: 0, largestWrite: 0)
        var drift = DriftController(targetFrames: plan.targetFrames, maximumFrames: plan.maximumFrames)
        ring.setPrimeLevel(plan.targetFrames)
        var input = [Float](repeating: 0.5, count: inputChunk)
        var left = [Float](repeating: 0, count: outputChunk * 2)
        var right = left
        var rateFactor = 1.0
        var outputDebt = 0.0
        let step = Double(inputChunk) / rate
        var nextTick = 0.0
        var time = 0.0
        while time < Double(seconds) {
            ring.write(left: &input, right: &input, frames: inputChunk)
            // The output consumes in big bursts, slightly slower than nominal.
            outputDebt += Double(inputChunk) * (1 - outputPPMSlow / 1e6) * rateFactor
            while outputDebt >= Double(outputChunk) {
                ring.read(left: &left, right: &right, frames: outputChunk)
                outputDebt -= Double(outputChunk)
            }
            if time >= nextTick {
                let updated = LatencyPlan(sampleRate: rate, largestRead: ring.largestRead, largestWrite: ring.largestWrite)
                if updated != plan {
                    plan = updated
                    drift.retarget(plan)
                    ring.setPrimeLevel(plan.targetFrames)
                }
                let decision = drift.update(fillFrames: ring.availableFrames)
                if let trim = decision.trimToFrames { ring.requestTrim(toFill: trim) }
                rateFactor = decision.rate
                nextTick += 0.1
            }
            time += step
        }
        return ring
    }

    @Test func largeOutputPullsDoNotKeepUnderrunning() {
        let ring = run(inputChunk: 256, outputChunk: 4096, outputPPMSlow: 300, seconds: 600)
        // At most the start-up learning period may run dry once.
        #expect(ring.totalUnderruns <= 1)
        #expect(ring.totalDropped == 0)
    }

    @Test func outputFasterThanInputStaysBounded() {
        let ring = run(inputChunk: 512, outputChunk: 1024, outputPPMSlow: -400, seconds: 600)
        #expect(ring.totalUnderruns <= 1)
        #expect(ring.totalDropped == 0)
    }

    @Test func planCoversBothChunkSizes() {
        let plan = LatencyPlan(sampleRate: 48_000, largestRead: 4096, largestWrite: 512)
        #expect(plan.targetFrames == 4096 + 512 + 480)
        #expect(LatencyPlan(sampleRate: 48_000, largestRead: 256, largestWrite: 256).targetFrames == 1920)
    }
}
