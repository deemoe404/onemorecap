@preconcurrency import Cocoa
import SubtitleCore
import SubtitlesAppSupport

protocol SubtitlePanelControllerDelegate: AnyObject {
    func subtitlePanel(_ panelController: SubtitlePanelController, didAdjustOffsetBy delta: TimeInterval)
    func subtitlePanelDidRequestAppleTVCalibration(_ panelController: SubtitlePanelController)
    func subtitlePanel(_ panelController: SubtitlePanelController, didRequestLoadURL url: URL)
    func subtitlePanelDidRequestClose(_ panelController: SubtitlePanelController)
}

final class SubtitlePanelController: NSObject, NSWindowDelegate, SubtitleOverlayViewDelegate, SubtitleToolbarViewDelegate {
    private enum InteractionState {
        case idle
        case hovering
        case toolbarHover
        case moving
        case resizing

        var isTransient: Bool {
            switch self {
            case .moving, .resizing:
                return true
            case .idle, .hovering, .toolbarHover:
                return false
            }
        }
    }

    weak var delegate: SubtitlePanelControllerDelegate?

    private let panel: SubtitlePanel
    private let overlayView = SubtitleOverlayView()
    private let toolbarPanel: SubtitlePanel
    private let toolbarView = SubtitleToolbarView()
    private let resizeCursorCoordinator: SubtitleResizeCursorCoordinator
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

    func subtitleOverlayView(_ view: SubtitleOverlayView, didRequestLoadURL url: URL) {
        delegate?.subtitlePanel(self, didRequestLoadURL: url)
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

        while let dragEvent = panel.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if dragEvent.type == .leftMouseUp {
                break
            }

            let nextFrame = frameByMoving(
                initialFrame: initialFrame,
                initialMouseLocation: initialMouseLocation,
                currentMouseLocation: NSEvent.mouseLocation
            )
            panel.setFrame(nextFrame, display: true)
            positionToolbarIfVisibleDuringTransientInteraction()
        }

        positionToolbarIfVisibleDuringTransientInteraction()

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
            panel.setFrame(
                frameByApplyingPreferredPanelHeightPreservingBottom(to: nextFrame, screenFrame: screenFrame),
                display: true
            )
        }

        panel.setFrame(
            frameByApplyingPreferredPanelHeightPreservingBottom(to: panel.frame, screenFrame: screenFrame),
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

    private func setContainerChromeVisible(_ visible: Bool, animated: Bool) {
        guard visible != containerChromeVisible else {
            return
        }
        containerChromeVisible = visible
        overlayView.setContainerChromeVisible(visible, animated: animated)
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

    private func applyPreferredPanelHeightAfterTransientInteraction() {
        let screenFrame = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        let nextFrame = frameByApplyingPreferredPanelHeightPreservingBottom(
            to: panel.frame,
            screenFrame: screenFrame
        )
        guard !panel.frame.isNearlyEqual(to: nextFrame) else {
            return
        }

        panel.setFrame(nextFrame, display: true)
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

    private func frameByApplyingPreferredPanelHeightPreservingBottom(
        to frame: NSRect,
        screenFrame: NSRect
    ) -> NSRect {
        SubtitlePanelGeometry.frameByApplyingPreferredHeightPreservingBottom(
            overlayView.preferredPanelHeight(forPanelWidth: frame.width),
            to: frame,
            screenFrame: screenFrame
        )
    }

    private static func defaultFrame() -> NSRect {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let width = min(max(screenFrame.width * 0.72, 640), 980)
        let height: CGFloat = 150
        return NSRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.minY + 72,
            width: width,
            height: height
        )
    }
}

final class SubtitlePanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
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
    func isNearlyEqual(to other: CGRect) -> Bool {
        abs(minX - other.minX) < 0.5 &&
            abs(minY - other.minY) < 0.5 &&
            abs(width - other.width) < 0.5 &&
            abs(height - other.height) < 0.5
    }
}
