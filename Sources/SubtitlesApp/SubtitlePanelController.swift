@preconcurrency import Cocoa
import QuartzCore
import SubtitleCore
import SubtitlesAppSupport

protocol SubtitlePanelControllerDelegate: AnyObject {
    func subtitlePanel(_ panelController: SubtitlePanelController, didAdjustOffsetBy delta: TimeInterval)
    func subtitlePanelDidRequestAppleTVCalibration(_ panelController: SubtitlePanelController)
    func subtitlePanel(_ panelController: SubtitlePanelController, didRequestLoadURL url: URL)
    func subtitlePanelDidRequestClose(_ panelController: SubtitlePanelController)
}

fileprivate protocol SubtitlePanelDraggingDelegate: AnyObject {
    func subtitlePanel(_ panel: SubtitlePanel, draggingEntered sender: NSDraggingInfo) -> NSDragOperation
    func subtitlePanel(_ panel: SubtitlePanel, draggingUpdated sender: NSDraggingInfo) -> NSDragOperation
    func subtitlePanel(_ panel: SubtitlePanel, performDragOperation sender: NSDraggingInfo) -> Bool
    func subtitlePanel(_ panel: SubtitlePanel, draggingExited sender: NSDraggingInfo?)
    func subtitlePanel(_ panel: SubtitlePanel, draggingEnded sender: NSDraggingInfo)
    func subtitlePanel(_ panel: SubtitlePanel, concludeDragOperation sender: NSDraggingInfo?)
}

final class SubtitlePanelController: NSObject, NSWindowDelegate, SubtitleOverlayViewDelegate, SubtitleToolbarViewDelegate, SubtitlePanelDraggingDelegate {
    private enum InteractionState {
        case idle
        case hovering
        case toolbarHover
        case subtitleFileDragHover
        case moving
        case resizing

        var isTransient: Bool {
            switch self {
            case .moving, .resizing:
                return true
            case .idle, .hovering, .toolbarHover, .subtitleFileDragHover:
                return false
            }
        }
    }

    private static let supportedSubtitleFileExtensions: Set<String> = ["srt", "vtt", "webvtt"]

    weak var delegate: SubtitlePanelControllerDelegate?

    private let panel: SubtitlePanel
    private let overlayView = SubtitleOverlayView()
    private let toolbarPanel: SubtitlePanel
    private let toolbarView = SubtitleToolbarView()
    private let snapPreviewPanel: SubtitleSnapPreviewPanel
    private let snapPreviewView = SubtitleSnapPreviewView()
    private let resizeCursorCoordinator: SubtitleResizeCursorCoordinator
    private var snapPreviewDesiredVisible = false
    private var snapPreviewHideInFlight = false
    private var snapPreviewFrame: NSRect?
    private var interactionState: InteractionState = .idle
    private var containerChromeVisible = false
    private var toolbarVisible = false
    private var pendingChromeHide: DispatchWorkItem?

    var isVisible: Bool {
        panel.isVisible
    }

    override init() {
        let frame = Self.defaultFrame()
        panel = SubtitlePanel(
            contentRect: frame,
            // Resize is handled by SubtitleOverlayView so AppKit does not expose
            // system resize strips in the panel's transparent margins.
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        toolbarPanel = SubtitlePanel(
            contentRect: NSRect(x: frame.midX - 240, y: frame.maxY + 8, width: 480, height: 36),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        snapPreviewPanel = SubtitleSnapPreviewPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        resizeCursorCoordinator = SubtitleResizeCursorCoordinator()
        super.init()

        panel.delegate = self
        panel.contentView = overlayView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.subtitleDraggingDelegate = self
        panel.registerForDraggedTypes([.fileURL])

        toolbarPanel.contentView = toolbarView
        toolbarPanel.isOpaque = false
        toolbarPanel.backgroundColor = .clear
        toolbarPanel.hasShadow = true
        toolbarPanel.hidesOnDeactivate = false
        toolbarPanel.level = .floating
        toolbarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        toolbarPanel.titleVisibility = .hidden
        toolbarPanel.titlebarAppearsTransparent = true
        toolbarPanel.alphaValue = 0

        snapPreviewPanel.contentView = snapPreviewView
        snapPreviewPanel.isOpaque = false
        snapPreviewPanel.backgroundColor = .clear
        snapPreviewPanel.hasShadow = false
        snapPreviewPanel.hidesOnDeactivate = false
        snapPreviewPanel.ignoresMouseEvents = true
        snapPreviewPanel.level = .floating
        snapPreviewPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        snapPreviewPanel.titleVisibility = .hidden
        snapPreviewPanel.titlebarAppearsTransparent = true

        overlayView.delegate = self
        toolbarView.delegate = self
        resizeCursorCoordinator.attach(panel: panel, overlayView: overlayView)
        panel.addChildWindow(toolbarPanel, ordered: .above)
    }

    deinit {
        resizeCursorCoordinator.stop()
    }

    func show() {
        if !panel.isVisible {
            panel.setFrame(Self.defaultFrame(), display: false)
        }
        overlayView.setCaptionReportingEnabled(true)
        panel.orderFrontRegardless()
        applyPreferredPanelHeightIfNeeded(display: true)
        resizeCursorCoordinator.start()
    }

    func hide() {
        pendingChromeHide?.cancel()
        pendingChromeHide = nil
        interactionState = .idle
        overlayView.setInteractionTrackingSuspended(false)
        setToolbarVisible(false, animated: false)
        setContainerChromeVisible(false, animated: false)
        hideDefaultPositionSnapPreview(animated: false)
        resizeCursorCoordinator.stop()
        overlayView.setCaptionReportingEnabled(false)
        panel.orderOut(nil)
    }

    func showMessage(_ message: String) {
        overlayView.subtitleText = message
    }

    func setPlaybackState(isPlaying: Bool, time: TimeInterval, offset: TimeInterval, sourceLabel: String = "Manual") {
        toolbarView.setPlaybackState(
            isPlaying: isPlaying,
            time: time,
            offset: offset,
            sourceLabel: sourceLabel
        )
        positionToolbarIfVisible()
    }

    func setLoadedFileName(_ fileName: String) {
        overlayView.setLoadedFileName(fileName)
        applyPreferredPanelHeightIfNeeded(display: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else {
            return
        }
        delegate?.subtitlePanelDidRequestClose(self)
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else {
            return
        }
        positionToolbarIfVisible()
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else {
            return
        }
        positionToolbarIfVisible()
    }

    func subtitleOverlayViewDidEnterInteractiveArea(_ view: SubtitleOverlayView) {
        guard !interactionState.isTransient else {
            return
        }
        interactionState = .hovering
        showInteractiveChrome(includeToolbar: true, animated: true)
    }

    func subtitleOverlayViewDidExitInteractiveArea(_ view: SubtitleOverlayView) {
        guard !interactionState.isTransient else {
            return
        }
        guard interactionState != .subtitleFileDragHover else {
            return
        }
        scheduleChromeHideIfNeeded()
    }

    func subtitleOverlayViewDidLayout(_ view: SubtitleOverlayView) {
        positionToolbarIfVisible()
    }

    func subtitleOverlayViewDidUpdatePreferredHeight(_ view: SubtitleOverlayView) {
        applyPreferredPanelHeightIfNeeded(display: true)
    }

    func subtitleOverlayView(
        _ view: SubtitleOverlayView,
        didRequestContainerResize edges: SubtitlePanelGeometry.ResizeEdges,
        initialMouseLocation: NSPoint
    ) {
        performContainerResize(edges: edges, initialMouseLocation: initialMouseLocation)
    }

    func subtitleOverlayView(_ view: SubtitleOverlayView, didRequestContainerMoveWith event: NSEvent) {
        performContainerMove(with: event)
    }

    func subtitlePanel(_ panel: SubtitlePanel, draggingEntered sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender)
    }

    func subtitlePanel(_ panel: SubtitlePanel, draggingUpdated sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender)
    }

    func subtitlePanel(_ panel: SubtitlePanel, performDragOperation sender: NSDraggingInfo) -> Bool {
        defer {
            finishSubtitleFileDrag()
        }

        guard
            overlayView.containsWindowPointInContainerArea(sender.draggingLocation),
            let url = Self.firstSupportedSubtitleURL(from: sender.draggingPasteboard)
        else {
            return false
        }

        delegate?.subtitlePanel(self, didRequestLoadURL: url)
        return true
    }

    func subtitlePanel(_ panel: SubtitlePanel, draggingExited sender: NSDraggingInfo?) {
        finishSubtitleFileDrag()
    }

    func subtitlePanel(_ panel: SubtitlePanel, draggingEnded sender: NSDraggingInfo) {
        finishSubtitleFileDrag()
    }

    func subtitlePanel(_ panel: SubtitlePanel, concludeDragOperation sender: NSDraggingInfo?) {
        finishSubtitleFileDrag()
    }

    func subtitleToolbarViewDidEnter(_ view: SubtitleToolbarView) {
        guard !interactionState.isTransient else {
            return
        }
        interactionState = .toolbarHover
        showInteractiveChrome(includeToolbar: true, animated: true)
    }

    func subtitleToolbarViewDidExit(_ view: SubtitleToolbarView) {
        guard !interactionState.isTransient else {
            return
        }
        scheduleChromeHideIfNeeded()
    }

    func subtitleToolbarView(_ view: SubtitleToolbarView, didAdjustOffsetBy delta: TimeInterval) {
        delegate?.subtitlePanel(self, didAdjustOffsetBy: delta)
    }

    func subtitleToolbarViewDidRequestAppleTVCalibration(_ view: SubtitleToolbarView) {
        delegate?.subtitlePanelDidRequestAppleTVCalibration(self)
    }

    private func performContainerMove(with _: NSEvent) {
        pendingChromeHide?.cancel()
        pendingChromeHide = nil
        interactionState = .moving
        overlayView.setInteractionTrackingSuspended(true)

        let initialFrame = panel.frame
        let initialMouseLocation = NSEvent.mouseLocation
        let initialScreenFrame = (panel.screen ?? NSScreen.main)?.visibleFrame ?? initialFrame
        var snapTargetContainerFrame: NSRect?

        while let dragEvent = panel.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let movedFrame = frameByMoving(
                initialFrame: initialFrame,
                initialMouseLocation: initialMouseLocation,
                currentMouseLocation: NSEvent.mouseLocation
            )
            let movedContainerFrame = SubtitlePanelGeometry.containerFrame(forWindowFrame: movedFrame)
            let movedScreenFrame = visibleScreenFrame(for: movedContainerFrame, fallback: initialScreenFrame)

            if dragEvent.type == .leftMouseUp {
                snapTargetContainerFrame = SubtitlePanelGeometry.defaultPositionSnapTargetFrame(
                    for: movedContainerFrame,
                    screenFrame: movedScreenFrame
                )
                if let snapTargetContainerFrame {
                    showDefaultPositionSnapPreview(frame: snapTargetContainerFrame)
                } else {
                    panel.setFrame(movedFrame, display: true)
                }
                break
            }

            snapTargetContainerFrame = updateDefaultPositionSnapPreview(
                forContainerFrame: movedContainerFrame,
                screenFrame: movedScreenFrame
            )
            panel.setFrame(movedFrame, display: true)
            positionToolbarIfVisibleDuringTransientInteraction()
        }

        if let snapTargetContainerFrame {
            animatePanelSnap(
                to: SubtitlePanelGeometry.windowFrame(containingContainerFrame: snapTargetContainerFrame)
            ) { [weak self] in
                self?.hideDefaultPositionSnapPreview()
            }
        } else {
            hideDefaultPositionSnapPreview()
            positionToolbarIfVisibleDuringTransientInteraction()
        }

        overlayView.setInteractionTrackingSuspended(false)
        if overlayView.containsScreenPointInContainerArea(NSEvent.mouseLocation) {
            interactionState = .hovering
            showInteractiveChrome(includeToolbar: true, animated: true)
        } else {
            interactionState = .idle
        }
        scheduleChromeHideIfNeeded()
    }

    private func frameByMoving(
        initialFrame: NSRect,
        initialMouseLocation: NSPoint,
        currentMouseLocation: NSPoint
    ) -> NSRect {
        let delta = NSPoint(
            x: currentMouseLocation.x - initialMouseLocation.x,
            y: currentMouseLocation.y - initialMouseLocation.y
        )
        return NSRect(
            x: initialFrame.minX + delta.x,
            y: initialFrame.minY + delta.y,
            width: initialFrame.width,
            height: initialFrame.height
        )
    }

    private func visibleScreenFrame(for frame: NSRect, fallback: NSRect) -> NSRect {
        let candidates = NSScreen.screens.map { screen in
            let intersection = screen.visibleFrame.intersection(frame)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            return (screenFrame: screen.visibleFrame, intersectionArea: area)
        }

        if let best = candidates.max(by: { $0.intersectionArea < $1.intersectionArea }),
           best.intersectionArea > 0 {
            return best.screenFrame
        }

        let frameCenter = NSPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.min { lhs, rhs in
            lhs.visibleFrame.center.squaredDistance(to: frameCenter) <
                rhs.visibleFrame.center.squaredDistance(to: frameCenter)
        }?.visibleFrame ?? fallback
    }

    private func performContainerResize(
        edges: SubtitlePanelGeometry.ResizeEdges,
        initialMouseLocation: NSPoint
    ) {
        pendingChromeHide?.cancel()
        pendingChromeHide = nil
        interactionState = .resizing
        overlayView.setInteractionTrackingSuspended(true)
        setContainerChromeVisible(true, animated: false)
        resizeCursorCoordinator.setForcedResizeEdges(edges)
        hideDefaultPositionSnapPreview(animated: false)

        let initialFrame = panel.frame
        let screenFrame = (panel.screen ?? NSScreen.main)?.visibleFrame ?? initialFrame

        while let resizeEvent = panel.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if resizeEvent.type == .leftMouseUp {
                break
            }

            let nextFrame = SubtitlePanelGeometry.resizedFrame(
                initialFrame: initialFrame,
                initialMouseLocation: initialMouseLocation,
                currentMouseLocation: NSEvent.mouseLocation,
                edges: edges,
                screenFrame: screenFrame
            )
            setPanelFrameIfNeeded(nextFrame, display: true)
        }

        setPanelFrameIfNeeded(
            SubtitlePanelGeometry.frameByFinishingTransientResize(
                panel.frame,
                preferredHeight: overlayView.preferredPanelHeight(forPanelWidth: panel.frame.width),
                screenFrame: screenFrame
            ),
            display: true
        )

        resizeCursorCoordinator.setForcedResizeEdges(nil)
        overlayView.setInteractionTrackingSuspended(false)
        interactionState = .hovering
        showInteractiveChrome(includeToolbar: true, animated: true)
        scheduleChromeHideIfNeeded()
    }

    private func showInteractiveChrome(includeToolbar: Bool, animated: Bool) {
        pendingChromeHide?.cancel()
        pendingChromeHide = nil
        setContainerChromeVisible(true, animated: animated)
        setToolbarVisible(includeToolbar, animated: animated)
    }

    private func hideInteractiveChrome(animated: Bool) {
        pendingChromeHide?.cancel()
        pendingChromeHide = nil
        interactionState = .idle
        setToolbarVisible(false, animated: animated)
        setContainerChromeVisible(false, animated: animated)
    }

    private func dragOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        guard Self.firstSupportedSubtitleURL(from: sender.draggingPasteboard) != nil else {
            updateSubtitleFileDragHover(isInsideContainer: false)
            return []
        }

        let isInsideContainer = overlayView.containsWindowPointInContainerArea(sender.draggingLocation)
        updateSubtitleFileDragHover(isInsideContainer: isInsideContainer)
        return isInsideContainer ? .copy : []
    }

    private func updateSubtitleFileDragHover(isInsideContainer: Bool) {
        guard !interactionState.isTransient else {
            return
        }

        if isInsideContainer {
            interactionState = .subtitleFileDragHover
            showInteractiveChrome(includeToolbar: true, animated: true)
        } else if interactionState == .subtitleFileDragHover {
            interactionState = .idle
            scheduleChromeHideIfNeeded()
        }
    }

    private func finishSubtitleFileDrag() {
        guard interactionState == .subtitleFileDragHover else {
            return
        }

        interactionState = .idle
        scheduleChromeHideIfNeeded()
    }

    private func setContainerChromeVisible(_ visible: Bool, animated: Bool) {
        guard visible != containerChromeVisible else {
            return
        }
        containerChromeVisible = visible
        overlayView.setContainerChromeVisible(visible, animated: animated)
    }

    private func updateDefaultPositionSnapPreview(
        forContainerFrame containerFrame: NSRect,
        screenFrame: NSRect
    ) -> NSRect? {
        guard let targetFrame = SubtitlePanelGeometry.defaultPositionSnapTargetFrame(
            for: containerFrame,
            screenFrame: screenFrame
        ) else {
            hideDefaultPositionSnapPreview()
            return nil
        }

        showDefaultPositionSnapPreview(frame: targetFrame)
        return targetFrame
    }

    private func animatePanelSnap(to frame: NSRect, completion: (() -> Void)? = nil) {
        guard !panel.frame.isNearlyEqual(to: frame) else {
            panel.setFrame(frame, display: true)
            positionToolbarIfVisibleDuringTransientInteraction()
            completion?()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            self?.positionToolbarIfVisible()
            completion?()
        }
    }

    private func showDefaultPositionSnapPreview(frame: NSRect) {
        if snapPreviewFrame?.isNearlyEqual(to: frame) != true {
            snapPreviewPanel.setFrame(frame, display: true)
            snapPreviewFrame = frame
        }

        if !snapPreviewPanel.isVisible {
            snapPreviewView.setIndicatorVisible(false, animated: false)
        }

        snapPreviewPanel.order(.below, relativeTo: panel.windowNumber)

        guard !snapPreviewDesiredVisible else {
            return
        }

        snapPreviewDesiredVisible = true
        snapPreviewHideInFlight = false
        snapPreviewView.setIndicatorVisible(true, animated: true)
    }

    private func hideDefaultPositionSnapPreview(animated: Bool = true) {
        guard snapPreviewDesiredVisible || snapPreviewPanel.isVisible else {
            return
        }

        if !snapPreviewDesiredVisible, snapPreviewHideInFlight {
            return
        }

        snapPreviewDesiredVisible = false

        guard animated else {
            snapPreviewHideInFlight = false
            snapPreviewFrame = nil
            snapPreviewView.setIndicatorVisible(false, animated: false)
            snapPreviewPanel.orderOut(nil)
            return
        }

        snapPreviewHideInFlight = true
        snapPreviewView.setIndicatorVisible(false, animated: true) { [weak self] in
            guard let self, !self.snapPreviewDesiredVisible else {
                return
            }
            self.snapPreviewHideInFlight = false
            self.snapPreviewFrame = nil
            self.snapPreviewPanel.orderOut(nil)
        }
    }

    private func setToolbarVisible(_ visible: Bool, animated: Bool) {
        guard visible != toolbarVisible else {
            if visible {
                positionToolbar()
            }
            return
        }

        toolbarVisible = visible

        if visible {
            positionToolbar()
            toolbarPanel.alphaValue = animated ? 0 : 1
            toolbarPanel.hasShadow = true
            toolbarPanel.orderFrontRegardless()
            invalidateToolbarPanelShadow(afterAnimation: animated)
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.12 : 0
            toolbarPanel.animator().alphaValue = visible ? 1 : 0
        } completionHandler: { [weak self] in
            guard let self, !self.toolbarVisible else {
                return
            }
            self.toolbarPanel.orderOut(nil)
            self.toolbarPanel.hasShadow = false
        }
    }

    private func scheduleChromeHideIfNeeded() {
        pendingChromeHide?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.hideChromeIfMouseOutside()
        }
        pendingChromeHide = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: workItem)
    }

    private func hideChromeIfMouseOutside() {
        pendingChromeHide = nil
        guard !interactionState.isTransient, containerChromeVisible, !mouseIsInsideChromeRegion() else {
            return
        }
        hideInteractiveChrome(animated: true)
    }

    private func mouseIsInsideChromeRegion() -> Bool {
        let mouseLocation = NSEvent.mouseLocation

        if overlayView.containsScreenPointInInteractiveArea(mouseLocation) {
            return true
        }

        if toolbarPanel.isVisible, toolbarPanel.frame.contains(mouseLocation) {
            return true
        }

        return false
    }

    private func positionToolbarIfVisible() {
        guard toolbarVisible, !interactionState.isTransient else {
            return
        }
        positionToolbar()
    }

    private func positionToolbarIfVisibleDuringTransientInteraction() {
        guard toolbarVisible else {
            return
        }
        positionToolbar()
    }

    private func positionToolbar() {
        toolbarView.layoutSubtreeIfNeeded()
        let fittingSize = toolbarView.intrinsicContentSize
        let screenFrame = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        let maxWidth = max(1, screenFrame.width - 16)
        let width = min(ceil(fittingSize.width), maxWidth)
        let height = ceil(fittingSize.height)
        let containerFrame = overlayView.containerFrameInScreen() ?? panel.frame

        let minimumX = screenFrame.minX + 8
        let maximumX = screenFrame.maxX - width - 8
        let minimumY = screenFrame.minY + 8
        let maximumY = screenFrame.maxY - height - 8

        let desiredX = containerFrame.midX - width / 2
        let desiredY = containerFrame.maxY + 8 - SubtitleToolbarView.glassRenderPadding
        let x = min(max(desiredX, minimumX), max(minimumX, maximumX))
        let y = min(max(desiredY, minimumY), max(minimumY, maximumY))

        toolbarPanel.setFrame(
            NSRect(x: x, y: y, width: width, height: height),
            display: true
        )
        toolbarPanel.invalidateShadow()
    }

    private func applyPreferredPanelHeightIfNeeded(display: Bool) {
        guard panel.isVisible, !interactionState.isTransient else {
            return
        }

        let screenFrame = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        let nextFrame = frameByApplyingPreferredPanelHeight(to: panel.frame, screenFrame: screenFrame)
        guard !panel.frame.isNearlyEqual(to: nextFrame) else {
            return
        }

        panel.setFrame(nextFrame, display: display)
        positionToolbarIfVisible()
    }

    private func invalidateToolbarPanelShadow(afterAnimation: Bool = false) {
        if toolbarPanel.hasShadow {
            toolbarPanel.invalidateShadow()
        }

        guard afterAnimation else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            guard let self else {
                return
            }
            if self.toolbarPanel.hasShadow {
                self.toolbarPanel.invalidateShadow()
            }
        }
    }

    private func frameByApplyingPreferredPanelHeight(to frame: NSRect, screenFrame: NSRect) -> NSRect {
        SubtitlePanelGeometry.frameByApplyingPreferredHeight(
            overlayView.preferredPanelHeight(forPanelWidth: frame.width),
            to: frame,
            screenFrame: screenFrame
        )
    }

    private func setPanelFrameIfNeeded(_ frame: NSRect, display: Bool) {
        guard !panel.frame.isNearlyEqual(to: frame) else {
            return
        }
        panel.setFrame(frame, display: display)
    }

    private static func defaultFrame() -> NSRect {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        return SubtitlePanelGeometry.defaultFrame(in: screenFrame)
    }

    private static func firstSupportedSubtitleURL(from pasteboard: NSPasteboard) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        return urls?.first { url in
            supportedSubtitleFileExtensions.contains(url.pathExtension.lowercased())
        }
    }
}

final class SubtitlePanel: NSPanel {
    fileprivate weak var subtitleDraggingDelegate: SubtitlePanelDraggingDelegate?

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    @objc func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        subtitleDraggingDelegate?.subtitlePanel(self, draggingEntered: sender) ?? []
    }

    @objc func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        subtitleDraggingDelegate?.subtitlePanel(self, draggingUpdated: sender) ?? []
    }

    @objc func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        subtitleDraggingDelegate?.subtitlePanel(self, performDragOperation: sender) ?? false
    }

    @objc func draggingExited(_ sender: NSDraggingInfo?) {
        subtitleDraggingDelegate?.subtitlePanel(self, draggingExited: sender)
    }

    @objc func draggingEnded(_ sender: NSDraggingInfo) {
        subtitleDraggingDelegate?.subtitlePanel(self, draggingEnded: sender)
    }

    @objc func concludeDragOperation(_ sender: NSDraggingInfo?) {
        subtitleDraggingDelegate?.subtitlePanel(self, concludeDragOperation: sender)
    }
}

private final class SubtitleSnapPreviewPanel: NSPanel {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}

private final class SubtitleSnapPreviewView: NSView {
    private static let lineWidth: CGFloat = 2
    private static let cornerRadius: CGFloat = 22
    private static let showDuration: CFTimeInterval = 0.14
    private static let hideDuration: CFTimeInterval = 0.16
    private static let reducedMotionDuration: CFTimeInterval = 0.07

    private let indicatorLayer = CALayer()
    private let fillLayer = CAShapeLayer()
    private let strokeLayer = CAShapeLayer()
    private var visibilityGeneration = 0
    private var modelOpacity: Float = 0

    override var isOpaque: Bool {
        false
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }

    override func layout() {
        super.layout()
        updateLayerGeometry()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLayerContentsScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateLayerContentsScale()
    }

    func setIndicatorVisible(_ visible: Bool, animated: Bool, completion: (() -> Void)? = nil) {
        visibilityGeneration += 1
        let generation = visibilityGeneration
        let targetOpacity: Float = visible ? 1 : 0

        let currentOpacity = indicatorLayer.presentation()?.opacity ?? modelOpacity

        indicatorLayer.removeAnimation(forKey: "snapPreviewVisibility")
        setLayerOpacity(targetOpacity)

        guard animated, abs(currentOpacity - targetOpacity) > 0.001 else {
            completion?()
            return
        }

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = currentOpacity
        opacity.toValue = targetOpacity

        let animationGroup = CAAnimationGroup()
        animationGroup.animations = [opacity]
        animationGroup.duration = animationDuration(visible: visible)
        animationGroup.timingFunction = CAMediaTimingFunction(name: visible ? .easeOut : .easeInEaseOut)
        animationGroup.isRemovedOnCompletion = true

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.visibilityGeneration == generation else {
                return
            }
            completion?()
        }
        indicatorLayer.add(animationGroup, forKey: "snapPreviewVisibility")
        CATransaction.commit()
    }

    private func setupLayers() {
        let rootLayer = CALayer()
        rootLayer.backgroundColor = NSColor.clear.cgColor
        rootLayer.masksToBounds = false
        layer = rootLayer
        wantsLayer = true

        indicatorLayer.masksToBounds = false
        setLayerOpacity(0)

        fillLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
        fillLayer.strokeColor = nil

        strokeLayer.fillColor = NSColor.clear.cgColor
        strokeLayer.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.86).cgColor
        strokeLayer.lineWidth = Self.lineWidth
        strokeLayer.lineDashPattern = [10, 7]
        strokeLayer.lineJoin = .round
        strokeLayer.lineCap = .round
        strokeLayer.allowsEdgeAntialiasing = true

        layer?.addSublayer(indicatorLayer)
        indicatorLayer.addSublayer(fillLayer)
        indicatorLayer.addSublayer(strokeLayer)
        updateLayerContentsScale()
    }

    private func updateLayerGeometry() {
        guard layer != nil else {
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        indicatorLayer.frame = bounds

        let indicatorBounds = indicatorLayer.bounds
        let rect = indicatorBounds.insetBy(dx: Self.lineWidth / 2, dy: Self.lineWidth / 2)
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: Self.cornerRadius,
            cornerHeight: Self.cornerRadius,
            transform: nil
        )

        for shapeLayer in [fillLayer, strokeLayer] {
            shapeLayer.frame = indicatorBounds
            shapeLayer.path = path
        }
        CATransaction.commit()
    }

    private func setLayerOpacity(_ opacity: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        indicatorLayer.opacity = opacity
        modelOpacity = opacity
        CATransaction.commit()
    }

    private func updateLayerContentsScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for layer in [layer, indicatorLayer, fillLayer, strokeLayer] {
            layer?.contentsScale = scale
        }
    }

    private func animationDuration(visible: Bool) -> CFTimeInterval {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            return Self.reducedMotionDuration
        }
        return visible ? Self.showDuration : Self.hideDuration
    }
}

private final class SubtitleResizeCursorCoordinator {
    private weak var panel: NSPanel?
    private weak var overlayView: SubtitleOverlayView?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var activeEdges: SubtitlePanelGeometry.ResizeEdges?
    private var forcedEdges: SubtitlePanelGeometry.ResizeEdges?
    private var didPushCursor = false

    func attach(panel: NSPanel, overlayView: SubtitleOverlayView) {
        self.panel = panel
        self.overlayView = overlayView
    }

    func start() {
        guard localMonitor == nil, globalMonitor == nil else {
            return
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.updateCursor()
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateCursor()
            }
        }

        updateCursor()
    }

    func stop() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        localMonitor = nil
        globalMonitor = nil
        forcedEdges = nil
        clearResizeCursorIfNeeded()
    }

    func setForcedResizeEdges(_ edges: SubtitlePanelGeometry.ResizeEdges?) {
        forcedEdges = edges
        updateCursor()
    }

    private func updateCursor() {
        guard let panel, panel.isVisible else {
            clearResizeCursorIfNeeded()
            return
        }

        if let forcedEdges {
            setResizeCursor(for: forcedEdges)
            return
        }

        guard let edges = overlayView?.resizeEdges(atScreenPoint: NSEvent.mouseLocation) else {
            clearResizeCursorIfNeeded()
            return
        }

        setResizeCursor(for: edges)
    }

    private func setResizeCursor(for edges: SubtitlePanelGeometry.ResizeEdges) {
        if didPushCursor, activeEdges == edges {
            return
        }

        clearResizeCursorIfNeeded()
        let cursor = NSCursor.frameResize(position: edges.cursorPosition, directions: .all)
        cursor.push()
        didPushCursor = true
        activeEdges = edges
    }

    private func clearResizeCursorIfNeeded() {
        guard didPushCursor else {
            return
        }

        NSCursor.pop()
        didPushCursor = false
        activeEdges = nil
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }

    func isNearlyEqual(to other: CGRect) -> Bool {
        abs(minX - other.minX) < 0.5 &&
            abs(minY - other.minY) < 0.5 &&
            abs(width - other.width) < 0.5 &&
            abs(height - other.height) < 0.5
    }
}

private extension CGPoint {
    func squaredDistance(to other: CGPoint) -> CGFloat {
        let dx = x - other.x
        let dy = y - other.y
        return dx * dx + dy * dy
    }
}
