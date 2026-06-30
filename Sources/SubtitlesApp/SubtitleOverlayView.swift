@preconcurrency import Cocoa
import SwiftUI
import SubtitlesAppSupport

protocol SubtitleOverlayViewDelegate: AnyObject {
    func subtitleOverlayViewDidEnterInteractiveArea(_ view: SubtitleOverlayView)
    func subtitleOverlayViewDidExitInteractiveArea(_ view: SubtitleOverlayView)
    func subtitleOverlayViewDidLayout(_ view: SubtitleOverlayView)
    func subtitleOverlayView(_ view: SubtitleOverlayView, didRequestContainerResize edges: SubtitlePanelGeometry.ResizeEdges, initialMouseLocation: NSPoint)
    func subtitleOverlayView(_ view: SubtitleOverlayView, didRequestContainerMoveWith event: NSEvent)
    func subtitleOverlayView(_ view: SubtitleOverlayView, didRequestLoadURL url: URL)
}

final class SubtitleOverlayView: NSView {
    private enum TrackingRole: String {
        case subtitle
        case container
    }

    private static let trackingRoleKey = "SubtitleOverlayTrackingRole"
    private static let resizeEdgesKey = "SubtitleOverlayResizeEdges"
    weak var delegate: SubtitleOverlayViewDelegate?

    private static let placeholderText = "Drop SRT or VTT subtitle here"

    var subtitleText: String = placeholderText {
        didSet {
            updateSubtitleText()
        }
    }

    private let subtitleBackdropView = NSView()
    private let subtitleLabel = NSTextField(labelWithString: placeholderText)
    private let containerChromeView = NSHostingView(rootView: SubtitleContainerChromeContentView())

    private var captionAppearance = SystemCaptionAppearance.current()
    private var captionAppearanceMonitor: SystemCaptionAppearanceMonitor?
    private var isContainerChromeVisible = false
    private var isInteractionTrackingSuspended = false
    private var isReportingCaptions = true
    private var lastReportedCaptionText: String?
    private var trackingAreaRefs: [NSTrackingArea] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
        startCaptionAppearanceMonitoring()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
        startCaptionAppearanceMonitoring()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard !isInteractionTrackingSuspended else {
            return
        }
        rebuildTrackingAreas()
    }

    override func layout() {
        super.layout()
        if !isInteractionTrackingSuspended {
            rebuildTrackingAreas()
            window?.invalidateCursorRects(for: self)
        }
        delegate?.subtitleOverlayViewDidLayout(self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()

        guard !isInteractionTrackingSuspended else {
            return
        }

        for (rect, edges) in SubtitlePanelGeometry.resizeCursorRects(in: containerRect()) {
            addCursorRect(
                rect,
                cursor: NSCursor.frameResize(position: edges.cursorPosition, directions: .all)
            )
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        guard let edges = resizeEdges(from: event) else {
            super.cursorUpdate(with: event)
            return
        }

        setResizeCursor(for: edges)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isInteractivePoint(point) || resizeEdges(at: point) != nil else {
            return nil
        }

        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        guard let event else {
            return false
        }

        let point = convert(event.locationInWindow, from: nil)
        return isInteractivePoint(point) || resizeEdges(at: point) != nil
    }

    override func mouseEntered(with event: NSEvent) {
        if let edges = resizeEdges(from: event) {
            setResizeCursor(for: edges)
            return
        }

        guard let role = trackingRole(from: event) else {
            return
        }

        switch role {
        case .subtitle:
            delegate?.subtitleOverlayViewDidEnterInteractiveArea(self)
        case .container:
            delegate?.subtitleOverlayViewDidEnterInteractiveArea(self)
        }
    }

    override func mouseExited(with event: NSEvent) {
        if resizeEdges(from: event) != nil {
            NSCursor.arrow.set()
            return
        }

        guard let point = currentMouseLocationInView(), isInteractivePoint(point) else {
            delegate?.subtitleOverlayViewDidExitInteractiveArea(self)
            return
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if let resizeEdges = resizeEdges(at: point) {
            delegate?.subtitleOverlayView(
                self,
                didRequestContainerResize: resizeEdges,
                initialMouseLocation: NSEvent.mouseLocation
            )
            return
        }

        guard isInteractivePoint(point) else {
            super.mouseDown(with: event)
            return
        }

        delegate?.subtitleOverlayView(self, didRequestContainerMoveWith: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        firstSupportedURL(from: sender.draggingPasteboard) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = firstSupportedURL(from: sender.draggingPasteboard) else {
            return false
        }
        delegate?.subtitleOverlayView(self, didRequestLoadURL: url)
        return true
    }

    func setCaptionReportingEnabled(_ enabled: Bool) {
        isReportingCaptions = enabled
        reportDisplayedCaptions(force: true)
    }

    func setInteractionTrackingSuspended(_ suspended: Bool) {
        guard suspended != isInteractionTrackingSuspended else {
            return
        }

        isInteractionTrackingSuspended = suspended
        if !suspended {
            rebuildTrackingAreas()
            window?.invalidateCursorRects(for: self)
        }
    }

    func setContainerChromeVisible(_ visible: Bool, animated: Bool) {
        guard visible != isContainerChromeVisible else {
            return
        }

        isContainerChromeVisible = visible
        if !isInteractionTrackingSuspended {
            rebuildTrackingAreas()
            window?.invalidateCursorRects(for: self)
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.12 : 0
            containerChromeView.animator().alphaValue = visible ? 1 : 0
        }
    }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 0
        registerForDraggedTypes([.fileURL])

        containerChromeView.translatesAutoresizingMaskIntoConstraints = false
        containerChromeView.alphaValue = 0
        containerChromeView.wantsLayer = true
        containerChromeView.layer?.backgroundColor = NSColor.clear.cgColor

        subtitleBackdropView.translatesAutoresizingMaskIntoConstraints = false
        subtitleBackdropView.wantsLayer = true
        subtitleBackdropView.layer?.backgroundColor = captionAppearance.windowColor.cgColor
        subtitleBackdropView.layer?.cornerRadius = captionAppearance.windowCornerRadius

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.alignment = .center
        subtitleLabel.maximumNumberOfLines = 3
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(containerChromeView)
        addSubview(subtitleBackdropView)
        subtitleBackdropView.addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            containerChromeView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SubtitlePanelGeometry.chromeInset),
            containerChromeView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SubtitlePanelGeometry.chromeInset),
            containerChromeView.topAnchor.constraint(equalTo: topAnchor, constant: SubtitlePanelGeometry.chromeInset),
            containerChromeView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -SubtitlePanelGeometry.chromeInset),

            subtitleBackdropView.centerXAnchor.constraint(equalTo: centerXAnchor),
            subtitleBackdropView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -6),
            subtitleBackdropView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            subtitleBackdropView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),

            subtitleLabel.leadingAnchor.constraint(equalTo: subtitleBackdropView.leadingAnchor, constant: 16),
            subtitleLabel.trailingAnchor.constraint(equalTo: subtitleBackdropView.trailingAnchor, constant: -16),
            subtitleLabel.topAnchor.constraint(equalTo: subtitleBackdropView.topAnchor, constant: 8),
            subtitleLabel.bottomAnchor.constraint(equalTo: subtitleBackdropView.bottomAnchor, constant: -8)
        ])

        updateSubtitleText()
    }

    private func rebuildTrackingAreas() {
        trackingAreaRefs.forEach { removeTrackingArea($0) }
        trackingAreaRefs.removeAll()

        addTrackingArea(for: subtitleBackdropView.frame, role: .subtitle)
        if isContainerChromeVisible {
            addTrackingArea(for: containerRect(), role: .container)
        }
        addResizeCursorTrackingAreas()
    }

    private func addTrackingArea(for rect: NSRect, role: TrackingRole) {
        guard rect.width > 0, rect.height > 0 else {
            return
        }

        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways]
        if let point = currentMouseLocationInView(), rect.contains(point) {
            options.insert(.assumeInside)
        }

        let trackingArea = NSTrackingArea(
            rect: rect,
            options: options,
            owner: self,
            userInfo: [Self.trackingRoleKey: role.rawValue]
        )
        addTrackingArea(trackingArea)
        trackingAreaRefs.append(trackingArea)
    }

    private func addResizeCursorTrackingAreas() {
        for (rect, edges) in SubtitlePanelGeometry.resizeCursorRects(in: containerRect()) {
            guard rect.width > 0, rect.height > 0 else {
                continue
            }

            let trackingArea = NSTrackingArea(
                rect: rect,
                options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways],
                owner: self,
                userInfo: [Self.resizeEdgesKey: edges.rawValue]
            )
            addTrackingArea(trackingArea)
            trackingAreaRefs.append(trackingArea)
        }
    }

    private func trackingRole(from event: NSEvent) -> TrackingRole? {
        guard
            let rawValue = event.trackingArea?.userInfo?[Self.trackingRoleKey] as? String,
            let role = TrackingRole(rawValue: rawValue)
        else {
            return nil
        }
        return role
    }

    private func resizeEdges(from event: NSEvent) -> SubtitlePanelGeometry.ResizeEdges? {
        guard
            let rawValue = event.trackingArea?.userInfo?[Self.resizeEdgesKey] as? Int
        else {
            return nil
        }

        return SubtitlePanelGeometry.ResizeEdges(rawValue: rawValue)
    }

    private func setResizeCursor(for edges: SubtitlePanelGeometry.ResizeEdges) {
        NSCursor.frameResize(position: edges.cursorPosition, directions: .all).set()
    }

    private func currentMouseLocationInView() -> NSPoint? {
        guard let window else {
            return nil
        }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return convert(windowPoint, from: nil)
    }

    private func isInteractivePoint(_ point: NSPoint) -> Bool {
        if subtitleBackdropView.frame.contains(point) {
            return true
        }

        if isContainerChromeVisible, containerRect().containsPointInclusively(point) {
            return true
        }

        return false
    }

    func containsScreenPointInInteractiveArea(_ screenPoint: NSPoint) -> Bool {
        guard let window else {
            return false
        }

        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let point = convert(windowPoint, from: nil)
        return isInteractivePoint(point)
    }

    func containsScreenPointInContainerArea(_ screenPoint: NSPoint) -> Bool {
        guard let window else {
            return false
        }

        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let point = convert(windowPoint, from: nil)
        return containerRect().containsPointInclusively(point)
    }

    func containerFrameInScreen() -> NSRect? {
        guard let window else {
            return nil
        }

        let windowFrame = convert(containerRect(), to: nil)
        return window.convertToScreen(windowFrame)
    }

    private func resizeEdges(at point: NSPoint) -> SubtitlePanelGeometry.ResizeEdges? {
        if isContainerChromeVisible {
            return SubtitlePanelGeometry.resizeEdges(
                at: point,
                in: containerRect(),
                isChromeVisible: true
            )
        }

        return SubtitlePanelGeometry.resizeEdges(at: point, in: containerRect())
    }

    private func containerRect() -> NSRect {
        SubtitlePanelGeometry.containerRect(in: bounds)
    }

    private func startCaptionAppearanceMonitoring() {
        captionAppearanceMonitor = SystemCaptionAppearanceMonitor { [weak self] in
            self?.applyCaptionAppearance(SystemCaptionAppearance.current())
        }
    }

    private func applyCaptionAppearance(_ appearance: SystemCaptionAppearance) {
        captionAppearance = appearance
        subtitleBackdropView.layer?.backgroundColor = appearance.windowColor.cgColor
        subtitleBackdropView.layer?.cornerRadius = appearance.windowCornerRadius
        updateSubtitleText()
    }

    private func updateSubtitleText() {
        let displayText = subtitleText.isEmpty ? " " : subtitleText
        subtitleLabel.attributedStringValue = NSAttributedString(
            string: displayText,
            attributes: captionAppearance.subtitleAttributes()
        )
        reportDisplayedCaptions()
    }

    private func reportDisplayedCaptions(force: Bool = false) {
        let captionText = isReportingCaptions ? reportableCaptionText() : nil
        guard force || captionText != lastReportedCaptionText else {
            return
        }

        SystemCaptionDisplayReporter.report(displayedText: captionText)
        lastReportedCaptionText = captionText
    }

    private func reportableCaptionText() -> String? {
        let trimmed = subtitleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, subtitleText != Self.placeholderText else {
            return nil
        }
        return subtitleText
    }

    private func firstSupportedURL(from pasteboard: NSPasteboard) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        return urls?.first { url in
            ["srt", "vtt", "webvtt"].contains(url.pathExtension.lowercased())
        }
    }

}

private struct SubtitleContainerChromeContentView: View {
    var body: some View {
        GlassEffectContainer {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassEffect(
                    .regular.interactive(),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                )
        }
        .environment(\.controlActiveState, .active)
    }
}

private extension SubtitlePanelGeometry.ResizeEdges {
    var cursorPosition: NSCursor.FrameResizePosition {
        switch (contains(.top), contains(.left), contains(.bottom), contains(.right)) {
        case (true, true, _, _):
            return .topLeft
        case (true, _, _, true):
            return .topRight
        case (_, true, true, _):
            return .bottomLeft
        case (_, _, true, true):
            return .bottomRight
        case (true, _, _, _):
            return .top
        case (_, true, _, _):
            return .left
        case (_, _, true, _):
            return .bottom
        case (_, _, _, true):
            return .right
        default:
            return .right
        }
    }
}

private extension CGRect {
    func containsPointInclusively(_ point: CGPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }
}
