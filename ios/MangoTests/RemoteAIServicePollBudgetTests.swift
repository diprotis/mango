import XCTest
@testable import Mango

/// Pins the client-side roadmap poll ceiling to the backend worker budget (0008 #11):
/// the worker Lambda may legitimately run up to 600s, so the client must keep polling
/// at least that long — never abandoning a job the worker is still running.
final class RemoteAIServicePollBudgetTests: XCTestCase {
    func testPollCeilingCoversWorkerBudget() {
        let workerBudget: Duration = .seconds(600)  // api_stack.py RoadmapWorkerFn timeout
        let ceiling = RemoteAIService.pollInterval * RemoteAIService.maxPolls
        XCTAssertGreaterThanOrEqual(ceiling, workerBudget)
    }
}
