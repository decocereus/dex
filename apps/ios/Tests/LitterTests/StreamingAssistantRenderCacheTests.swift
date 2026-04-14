import XCTest
@testable import Litter

@MainActor
final class StreamingAssistantRenderCacheTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StreamingAssistantRenderCache.shared.reset()
    }

    func testAppendOnlyStreamingReusesStablePrefixSegments() {
        let itemId = "assistant-1"
        let prefix = String(repeating: "alpha ", count: 300) + "\n\n"
        let tail = String(repeating: "beta ", count: 1000)
        let initialText = prefix + tail
        let appendedText = initialText + "gamma"

        let initialSegments = StreamingAssistantRenderCache.shared.segments(
            itemId: itemId,
            text: initialText
        )
        let appendedSegments = StreamingAssistantRenderCache.shared.segments(
            itemId: itemId,
            text: appendedText
        )

        XCTAssertGreaterThanOrEqual(initialSegments.count, 2)
        XCTAssertGreaterThanOrEqual(appendedSegments.count, 2)
        XCTAssertEqual(initialSegments.first?.id, appendedSegments.first?.id)
        XCTAssertNotEqual(initialSegments.last?.id, appendedSegments.last?.id)
    }

    func testNonAppendEditRebuildsStreamingSegments() {
        let itemId = "assistant-2"
        let prefix = String(repeating: "alpha ", count: 300) + "\n\n"
        let tail = String(repeating: "beta ", count: 1000)
        let initialText = prefix + tail
        let editedText = "omega " + String(initialText.dropFirst("alpha ".count))

        let initialSegments = StreamingAssistantRenderCache.shared.segments(
            itemId: itemId,
            text: initialText
        )
        let editedSegments = StreamingAssistantRenderCache.shared.segments(
            itemId: itemId,
            text: editedText
        )

        XCTAssertFalse(initialSegments.isEmpty)
        XCTAssertFalse(editedSegments.isEmpty)
        XCTAssertNotEqual(initialSegments.first?.id, editedSegments.first?.id)
    }
}
