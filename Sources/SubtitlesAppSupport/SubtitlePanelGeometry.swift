import CoreGraphics

public enum SubtitlePanelGeometry {
    public struct ResizeEdges: OptionSet, Equatable, Sendable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let left = ResizeEdges(rawValue: 1 << 0)
        public static let right = ResizeEdges(rawValue: 1 << 1)
        public static let top = ResizeEdges(rawValue: 1 << 2)
        public static let bottom = ResizeEdges(rawValue: 1 << 3)
    }

    public static let chromeInset: CGFloat = 32
    public static let chromeRenderMargin: CGFloat = 20
    public static let resizeEdgeThickness: CGFloat = 28
    public static let minimumWidth: CGFloat = 420
    public static let maximumWidth: CGFloat = 1400
    public static let minimumHeight: CGFloat = 96

    public static func containerRect(in bounds: CGRect) -> CGRect {
        let inset = min(chromeInset, bounds.width / 2, bounds.height / 2)
        return bounds.insetBy(dx: inset, dy: inset)
    }

    public static func chromeRenderRect(in bounds: CGRect) -> CGRect {
        let container = containerRect(in: bounds)
        let margin = min(
            chromeRenderMargin,
            container.minX - bounds.minX,
            bounds.maxX - container.maxX,
            container.minY - bounds.minY,
            bounds.maxY - container.maxY
        )
        return container.insetBy(dx: -margin, dy: -margin)
    }

    public static func resizeEdges(
        at point: CGPoint,
        in containerRect: CGRect,
        isChromeVisible: Bool
    ) -> ResizeEdges? {
        guard isChromeVisible else {
            return nil
        }
        return resizeEdges(at: point, in: containerRect)
    }

    public static func resizeEdges(
        at point: CGPoint,
        in containerRect: CGRect
    ) -> ResizeEdges? {
        guard containerRect.containsInclusively(point) else {
            return nil
        }

        var edges: ResizeEdges = []

        if point.x <= containerRect.minX + resizeEdgeThickness {
            edges.insert(.left)
        } else if point.x >= containerRect.maxX - resizeEdgeThickness {
            edges.insert(.right)
        }

        return edges.isEmpty ? nil : edges
    }

    public static func resizeCursorRects(in containerRect: CGRect) -> [(CGRect, ResizeEdges)] {
        let edge = min(resizeEdgeThickness, containerRect.width / 2)
        guard edge > 0 else {
            return []
        }

        return [
            (CGRect(x: containerRect.minX, y: containerRect.minY, width: edge, height: containerRect.height), .left),
            (CGRect(x: containerRect.maxX - edge, y: containerRect.minY, width: edge, height: containerRect.height), .right)
        ].filter { rect, _ in
            rect.width > 0 && rect.height > 0
        }
    }

    public static func resizedFrame(
        initialFrame: CGRect,
        initialMouseLocation: CGPoint,
        currentMouseLocation: CGPoint,
        edges: ResizeEdges,
        screenFrame: CGRect
    ) -> CGRect {
        let delta = CGPoint(
            x: currentMouseLocation.x - initialMouseLocation.x,
            y: currentMouseLocation.y - initialMouseLocation.y
        )
        let minimumWidth = min(Self.minimumWidth, screenFrame.width)
        let maximumWidth = min(max(Self.maximumWidth, minimumWidth), screenFrame.width)

        var left = initialFrame.minX
        var right = initialFrame.maxX

        if edges.contains(.left) {
            let fixedRight = initialFrame.maxX
            let minimumLeft = max(screenFrame.minX, fixedRight - maximumWidth)
            let maximumLeft = fixedRight - minimumWidth
            left = clampLowerResizeEdge(initialFrame.minX + delta.x, minimumLeft, maximumLeft)
            right = fixedRight
        } else if edges.contains(.right) {
            let fixedLeft = initialFrame.minX
            let minimumRight = fixedLeft + minimumWidth
            let maximumRight = min(screenFrame.maxX, fixedLeft + maximumWidth)
            left = fixedLeft
            right = clampUpperResizeEdge(initialFrame.maxX + delta.x, minimumRight, maximumRight)
        }

        return CGRect(x: left, y: initialFrame.minY, width: right - left, height: initialFrame.height)
    }

    public static func frameByApplyingPreferredHeight(
        _ preferredHeight: CGFloat,
        to frame: CGRect,
        screenFrame: CGRect
    ) -> CGRect {
        let height = min(max(preferredHeight, min(Self.minimumHeight, screenFrame.height)), screenFrame.height)
        let y = clamp(frame.midY - height / 2, screenFrame.minY, screenFrame.maxY - height)
        return CGRect(x: frame.minX, y: y, width: frame.width, height: height)
    }

    public static func frameByApplyingPreferredHeightPreservingBottom(
        _ preferredHeight: CGFloat,
        to frame: CGRect,
        screenFrame: CGRect
    ) -> CGRect {
        let height = min(max(preferredHeight, min(Self.minimumHeight, screenFrame.height)), screenFrame.height)
        let y = clamp(frame.minY, screenFrame.minY, screenFrame.maxY - height)
        return CGRect(x: frame.minX, y: y, width: frame.width, height: height)
    }

    public static func clampedFrame(_ frame: CGRect, to screenFrame: CGRect) -> CGRect {
        let width = min(max(frame.width, min(Self.minimumWidth, screenFrame.width)), min(Self.maximumWidth, screenFrame.width))
        let height = min(max(frame.height, min(Self.minimumHeight, screenFrame.height)), screenFrame.height)
        let x = clamp(frame.minX, screenFrame.minX, screenFrame.maxX - width)
        let y = clamp(frame.minY, screenFrame.minY, screenFrame.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func clamp(_ value: CGFloat, _ lowerBound: CGFloat, _ upperBound: CGFloat) -> CGFloat {
        min(max(value, lowerBound), upperBound)
    }

    private static func clampLowerResizeEdge(_ value: CGFloat, _ lowerBound: CGFloat, _ upperBound: CGFloat) -> CGFloat {
        guard lowerBound <= upperBound else {
            return upperBound
        }
        return clamp(value, lowerBound, upperBound)
    }

    private static func clampUpperResizeEdge(_ value: CGFloat, _ lowerBound: CGFloat, _ upperBound: CGFloat) -> CGFloat {
        guard lowerBound <= upperBound else {
            return lowerBound
        }
        return clamp(value, lowerBound, upperBound)
    }
}

private extension CGRect {
    func containsInclusively(_ point: CGPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }
}
