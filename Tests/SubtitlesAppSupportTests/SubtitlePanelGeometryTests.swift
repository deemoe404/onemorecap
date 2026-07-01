import CoreGraphics
import XCTest
@testable import SubtitlesAppSupport

final class SubtitlePanelGeometryTests: XCTestCase {
    private let screenFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)

    func testContainerRectUsesStableInset() {
        let rect = SubtitlePanelGeometry.containerRect(in: CGRect(x: 0, y: 0, width: 900, height: 160))

        XCTAssertEqual(rect, CGRect(x: 32, y: 32, width: 836, height: 96))
    }

    func testChromeRenderRectExpandsAroundContainerWithoutLeavingBounds() {
        let rect = SubtitlePanelGeometry.chromeRenderRect(in: CGRect(x: 0, y: 0, width: 900, height: 160))

        XCTAssertEqual(rect, CGRect(x: 12, y: 12, width: 876, height: 136))
    }

    func testEdgeHitTestRequiresVisibleChrome() {
        let container = CGRect(x: 12, y: 12, width: 876, height: 136)
        let point = CGPoint(x: 13, y: 80)

        XCTAssertNil(SubtitlePanelGeometry.resizeEdges(at: point, in: container, isChromeVisible: false))
        XCTAssertEqual(
            SubtitlePanelGeometry.resizeEdges(at: point, in: container, isChromeVisible: true),
            .left
        )
    }

    func testEdgeHitTestCanRunWithoutChromeVisibilityGate() {
        let container = CGRect(x: 12, y: 12, width: 876, height: 136)

        XCTAssertEqual(
            SubtitlePanelGeometry.resizeEdges(at: CGPoint(x: container.maxX - 2, y: container.midY), in: container),
            .right
        )
        XCTAssertNil(
            SubtitlePanelGeometry.resizeEdges(at: CGPoint(x: container.midX, y: container.midY), in: container)
        )
    }

    func testEdgeHitTestTreatsCornersAsHorizontalResizeOnly() {
        let container = CGRect(x: 12, y: 12, width: 876, height: 136)

        XCTAssertEqual(
            SubtitlePanelGeometry.resizeEdges(
                at: CGPoint(x: container.minX + 2, y: container.maxY - 2),
                in: container,
                isChromeVisible: true
            ),
            .left
        )
        XCTAssertEqual(
            SubtitlePanelGeometry.resizeEdges(
                at: CGPoint(x: container.maxX - 2, y: container.minY + 2),
                in: container,
                isChromeVisible: true
            ),
            .right
        )
        XCTAssertNil(
            SubtitlePanelGeometry.resizeEdges(
                at: CGPoint(x: container.midX, y: container.midY),
                in: container,
                isChromeVisible: true
            )
        )
    }

    func testEdgeHitTestIncludesExactRightAndTopBoundaries() {
        let container = CGRect(x: 12, y: 12, width: 876, height: 136)

        XCTAssertEqual(
            SubtitlePanelGeometry.resizeEdges(
                at: CGPoint(x: container.maxX, y: container.maxY),
                in: container,
                isChromeVisible: true
            ),
            .right
        )
        XCTAssertNil(
            SubtitlePanelGeometry.resizeEdges(
                at: CGPoint(x: container.midX, y: container.maxY),
                in: container,
                isChromeVisible: true
            )
        )
    }

    func testHorizontalResizeEdgeThicknessBoundaries() {
        let container = CGRect(x: 12, y: 12, width: 876, height: 136)
        let edge = SubtitlePanelGeometry.resizeEdgeThickness

        XCTAssertEqual(
            SubtitlePanelGeometry.resizeEdges(
                at: CGPoint(x: container.minX + edge, y: container.midY),
                in: container,
                isChromeVisible: true
            ),
            .left
        )
        XCTAssertNil(
            SubtitlePanelGeometry.resizeEdges(
                at: CGPoint(x: container.minX + edge + 0.5, y: container.midY),
                in: container,
                isChromeVisible: true
            )
        )
        XCTAssertEqual(
            SubtitlePanelGeometry.resizeEdges(
                at: CGPoint(x: container.maxX - edge, y: container.midY),
                in: container,
                isChromeVisible: true
            ),
            .right
        )
        XCTAssertNil(
            SubtitlePanelGeometry.resizeEdges(
                at: CGPoint(x: container.maxX - edge - 0.5, y: container.midY),
                in: container,
                isChromeVisible: true
            )
        )
    }

    func testLeftResizeKeepsRightEdgeStable() {
        let initial = CGRect(x: 200, y: 100, width: 800, height: 150)

        let resized = SubtitlePanelGeometry.resizedFrame(
            initialFrame: initial,
            initialMouseLocation: CGPoint(x: 200, y: 180),
            currentMouseLocation: CGPoint(x: 260, y: 180),
            edges: .left,
            screenFrame: screenFrame
        )

        XCTAssertEqual(resized.minX, 260)
        XCTAssertEqual(resized.maxX, initial.maxX)
        XCTAssertEqual(resized.width, 740)
    }

    func testRightResizeClampsToScreenAndMaximumWidth() {
        let initial = CGRect(x: 100, y: 100, width: 800, height: 150)

        let resized = SubtitlePanelGeometry.resizedFrame(
            initialFrame: initial,
            initialMouseLocation: CGPoint(x: initial.maxX, y: 180),
            currentMouseLocation: CGPoint(x: 2_000, y: 180),
            edges: .right,
            screenFrame: screenFrame
        )

        XCTAssertEqual(resized.minX, initial.minX)
        XCTAssertEqual(resized.maxX, screenFrame.maxX)
        XCTAssertEqual(resized.width, 1_100)
    }

    func testTopResizeRequestDoesNotChangeFrame() {
        let initial = CGRect(x: 200, y: 650, width: 800, height: 120)

        let resized = SubtitlePanelGeometry.resizedFrame(
            initialFrame: initial,
            initialMouseLocation: CGPoint(x: initial.midX, y: initial.maxY),
            currentMouseLocation: CGPoint(x: initial.midX, y: 1_000),
            edges: .top,
            screenFrame: screenFrame
        )

        XCTAssertEqual(resized, initial)
    }

    func testBottomResizeRequestDoesNotChangeFrame() {
        let initial = CGRect(x: 200, y: 20, width: 800, height: 120)

        let resized = SubtitlePanelGeometry.resizedFrame(
            initialFrame: initial,
            initialMouseLocation: CGPoint(x: initial.midX, y: initial.minY),
            currentMouseLocation: CGPoint(x: initial.midX, y: -200),
            edges: .bottom,
            screenFrame: screenFrame
        )

        XCTAssertEqual(resized, initial)
    }

    func testCornerResizeRequestOnlyChangesWidth() {
        let initial = CGRect(x: 200, y: 100, width: 800, height: 150)

        let resized = SubtitlePanelGeometry.resizedFrame(
            initialFrame: initial,
            initialMouseLocation: CGPoint(x: initial.maxX, y: initial.maxY),
            currentMouseLocation: CGPoint(x: 300, y: 120),
            edges: [.right, .top],
            screenFrame: screenFrame
        )

        XCTAssertEqual(resized.minX, initial.minX)
        XCTAssertEqual(resized.minY, initial.minY)
        XCTAssertEqual(resized.width, SubtitlePanelGeometry.minimumWidth)
        XCTAssertEqual(resized.height, initial.height)
    }

    func testPreferredHeightFrameKeepsVerticalCenterStable() {
        let initial = CGRect(x: 200, y: 100, width: 800, height: 150)

        let adjusted = SubtitlePanelGeometry.frameByApplyingPreferredHeight(
            220,
            to: initial,
            screenFrame: screenFrame
        )

        XCTAssertEqual(adjusted.midY, initial.midY)
        XCTAssertEqual(adjusted.height, 220)
        XCTAssertEqual(adjusted.width, initial.width)
    }

    func testPreferredHeightFrameClampsToVisibleScreen() {
        let initial = CGRect(x: 200, y: 760, width: 800, height: 80)

        let adjusted = SubtitlePanelGeometry.frameByApplyingPreferredHeight(
            180,
            to: initial,
            screenFrame: screenFrame
        )

        XCTAssertEqual(adjusted.maxY, screenFrame.maxY)
        XCTAssertEqual(adjusted.height, 180)
    }

    func testPreferredHeightFrameDoesNotChangeHorizontalGeometry() {
        let initial = CGRect(x: 900, y: 100, width: 500, height: 150)

        let adjusted = SubtitlePanelGeometry.frameByApplyingPreferredHeight(
            220,
            to: initial,
            screenFrame: screenFrame
        )

        XCTAssertEqual(adjusted.minX, initial.minX)
        XCTAssertEqual(adjusted.width, initial.width)
        XCTAssertEqual(adjusted.height, 220)
    }

    func testPreferredHeightFramePreservingBottomKeepsBottomStable() {
        let initial = CGRect(x: 200, y: 100, width: 800, height: 150)

        let adjusted = SubtitlePanelGeometry.frameByApplyingPreferredHeightPreservingBottom(
            220,
            to: initial,
            screenFrame: screenFrame
        )

        XCTAssertEqual(adjusted.minY, initial.minY)
        XCTAssertEqual(adjusted.height, 220)
        XCTAssertEqual(adjusted.width, initial.width)
    }

    func testPreferredHeightFramePreservingBottomClampsToVisibleScreen() {
        let initial = CGRect(x: 200, y: 760, width: 800, height: 80)

        let adjusted = SubtitlePanelGeometry.frameByApplyingPreferredHeightPreservingBottom(
            180,
            to: initial,
            screenFrame: screenFrame
        )

        XCTAssertEqual(adjusted.maxY, screenFrame.maxY)
        XCTAssertEqual(adjusted.height, 180)
    }

    func testClampedFrameStaysInsideScreen() {
        let frame = CGRect(x: -200, y: -50, width: 2_000, height: 900)

        let clamped = SubtitlePanelGeometry.clampedFrame(frame, to: screenFrame)

        XCTAssertEqual(clamped.minX, screenFrame.minX)
        XCTAssertEqual(clamped.minY, screenFrame.minY)
        XCTAssertEqual(clamped.width, screenFrame.width)
        XCTAssertEqual(clamped.height, screenFrame.height)
    }

    func testResizeFromOffscreenFrameDoesNotShiftFixedEdge() {
        let initial = CGRect(x: 900, y: 100, width: 500, height: 150)

        let resized = SubtitlePanelGeometry.resizedFrame(
            initialFrame: initial,
            initialMouseLocation: CGPoint(x: initial.maxX, y: initial.midY),
            currentMouseLocation: CGPoint(x: initial.maxX + 100, y: initial.midY),
            edges: .right,
            screenFrame: screenFrame
        )

        XCTAssertEqual(resized.minX, initial.minX)
        XCTAssertEqual(resized.width, SubtitlePanelGeometry.minimumWidth)
    }
}
