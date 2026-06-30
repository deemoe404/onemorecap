@preconcurrency import Cocoa
import SubtitleCore

protocol SubtitlePanelControllerDelegate: AnyObject {
    func subtitlePanelDidRequestPlayPause(_ panelController: SubtitlePanelController)
    func subtitlePanelDidRequestReset(_ panelController: SubtitlePanelController)
    func subtitlePanel(_ panelController: SubtitlePanelController, didAdjustOffsetBy delta: TimeInterval)
    func subtitlePanelDidRequestAppleTVCalibration(_ panelController: SubtitlePanelController)
    func subtitlePanel(_ panelController: SubtitlePanelController, didRequestLoadURL url: URL)
    func subtitlePanelDidRequestClose(_ panelController: SubtitlePanelController)
}

final class SubtitlePanelController: NSObject, NSWindowDelegate, SubtitleOverlayViewDelegate, SubtitleToolbarViewDelegate {
    weak var delegate: SubtitlePanelControllerDelegate?

    private let panel: SubtitlePanel
    private let overlayView = SubtitleOverlayView()
    private let toolbarPanel: SubtitlePanel
    private let toolbarView = SubtitleToolbarView()
    private var chromeVisible = false
    private var pendingChromeHide: DispatchWorkItem?
    private var pendingMoveRestore: DispatchWorkItem?
    private var shouldRestoreToolbarAfterMove = false
    private var isSubtitleWindowMoving = false

    var isVisible: Bool {
        panel.isVisible
    }

    override init() {
        let frame = Self.defaultFrame()
        panel = SubtitlePanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        toolbarPanel = SubtitlePanel(
            contentRect: NSRect(x: frame.midX - 240, y: frame.maxY + 8, width: 480, height: 36),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.delegate = self
        panel.contentView = overlayView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        toolbarPanel.contentView = toolbarView
        toolbarPanel.isOpaque = false
        toolbarPanel.backgroundColor = .clear
        toolbarPanel.hasShadow = false
        toolbarPanel.hidesOnDeactivate = false
        toolbarPanel.level = .screenSaver
        toolbarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        toolbarPanel.titleVisibility = .hidden
        toolbarPanel.titlebarAppearsTransparent = true
        toolbarPanel.alphaValue = 0

        overlayView.delegate = self
        toolbarView.delegate = self
        panel.addChildWindow(toolbarPanel, ordered: .above)
    }

    func show() {
        if !panel.isVisible {
            panel.setFrame(Self.defaultFrame(), display: false)
        }
        overlayView.setCaptionReportingEnabled(true)
        panel.orderFrontRegardless()
    }

    func hide() {
        pendingMoveRestore?.cancel()
        pendingMoveRestore = nil
        shouldRestoreToolbarAfterMove = false
        isSubtitleWindowMoving = false
        setChromeVisible(false, animated: false)
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
        toolbarView.setLoadedFileName(fileName)
        positionToolbarIfVisible()
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
        handleSubtitlePanelMove()
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else {
            return
        }
        positionToolbarIfVisible()
    }

    func subtitleOverlayViewDidEnterInteractiveArea(_ view: SubtitleOverlayView) {
        if isSubtitleWindowMoving {
            shouldRestoreToolbarAfterMove = true
            return
        }
        setChromeVisible(true, animated: true)
    }

    func subtitleOverlayViewDidExitInteractiveArea(_ view: SubtitleOverlayView) {
        scheduleChromeHideIfNeeded()
    }

    func subtitleOverlayViewDidLayout(_ view: SubtitleOverlayView) {
        positionToolbarIfVisible()
    }

    func subtitleOverlayView(_ view: SubtitleOverlayView, didRequestLoadURL url: URL) {
        delegate?.subtitlePanel(self, didRequestLoadURL: url)
    }

    func subtitleToolbarViewDidEnter(_ view: SubtitleToolbarView) {
        if isSubtitleWindowMoving {
            shouldRestoreToolbarAfterMove = true
            return
        }
        setChromeVisible(true, animated: true)
    }

    func subtitleToolbarViewDidExit(_ view: SubtitleToolbarView) {
        scheduleChromeHideIfNeeded()
    }

    func subtitleToolbarView(_ view: SubtitleToolbarView, didRequestScale factor: CGFloat) {
        scaleSubtitlePanel(by: factor)
    }

    func subtitleToolbarView(_ view: SubtitleToolbarView, didAdjustOffsetBy delta: TimeInterval) {
        delegate?.subtitlePanel(self, didAdjustOffsetBy: delta)
    }

    func subtitleToolbarViewDidRequestAppleTVCalibration(_ view: SubtitleToolbarView) {
        delegate?.subtitlePanelDidRequestAppleTVCalibration(self)
    }

    func subtitleToolbarViewDidRequestPlayPause(_ view: SubtitleToolbarView) {
        delegate?.subtitlePanelDidRequestPlayPause(self)
    }

    func subtitleToolbarViewDidRequestReset(_ view: SubtitleToolbarView) {
        delegate?.subtitlePanelDidRequestReset(self)
    }

    private func scaleSubtitlePanel(by factor: CGFloat) {
        let current = panel.frame
        let newWidth = min(max(current.width * factor, 420), 1400)
        let newHeight = min(max(current.height * factor, 110), 360)
        let newFrame = NSRect(
            x: current.midX - newWidth / 2,
            y: current.midY - newHeight / 2,
            width: newWidth,
            height: newHeight
        )
        panel.setFrame(newFrame, display: true, animate: true)
        positionToolbarIfVisible()
    }

    private func handleSubtitlePanelMove() {
        guard chromeVisible || shouldRestoreToolbarAfterMove else {
            return
        }

        if !isSubtitleWindowMoving {
            isSubtitleWindowMoving = true
            shouldRestoreToolbarAfterMove = chromeVisible
            if chromeVisible {
                setChromeVisible(false, animated: true)
            }
        }

        scheduleToolbarRestoreAfterMove()
    }

    private func scheduleToolbarRestoreAfterMove() {
        pendingMoveRestore?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.finishSubtitlePanelMove()
        }
        pendingMoveRestore = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }

    private func finishSubtitlePanelMove() {
        pendingMoveRestore = nil
        isSubtitleWindowMoving = false

        guard shouldRestoreToolbarAfterMove else {
            return
        }

        shouldRestoreToolbarAfterMove = false
        positionToolbar()
        setChromeVisible(true, animated: true)
    }

    private func setChromeVisible(_ visible: Bool, animated: Bool) {
        pendingChromeHide?.cancel()
        pendingChromeHide = nil

        guard visible != chromeVisible else {
            if visible {
                positionToolbar()
            }
            return
        }

        chromeVisible = visible

        if visible {
            positionToolbar()
            toolbarPanel.alphaValue = animated ? 0 : 1
            toolbarPanel.orderFrontRegardless()
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.12 : 0
            toolbarPanel.animator().alphaValue = visible ? 1 : 0
        } completionHandler: { [weak self] in
            guard let self, !self.chromeVisible else {
                return
            }
            self.toolbarPanel.orderOut(nil)
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
        guard chromeVisible, !mouseIsInsideChromeRegion() else {
            return
        }
        setChromeVisible(false, animated: true)
    }

    private func mouseIsInsideChromeRegion() -> Bool {
        let mouseLocation = NSEvent.mouseLocation

        if overlayView.containsScreenPointInInteractiveArea(mouseLocation) {
            return true
        }

        guard toolbarPanel.isVisible else {
            return false
        }

        if toolbarPanel.frame.contains(mouseLocation) {
            return true
        }

        guard let subtitleFrame = overlayView.subtitleBackdropFrameInScreen() else {
            return false
        }

        return subtitleFrame.union(toolbarPanel.frame).insetBy(dx: -6, dy: -6).contains(mouseLocation)
    }

    private func positionToolbarIfVisible() {
        guard chromeVisible, !isSubtitleWindowMoving else {
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
        let subtitleFrame = overlayView.subtitleBackdropFrameInScreen() ?? panel.frame

        let minimumX = screenFrame.minX + 8
        let maximumX = screenFrame.maxX - width - 8
        let minimumY = screenFrame.minY + 8
        let maximumY = screenFrame.maxY - height - 8

        let desiredX = subtitleFrame.midX - width / 2
        let desiredY = subtitleFrame.maxY + 8
        let x = min(max(desiredX, minimumX), max(minimumX, maximumX))
        let y = min(max(desiredY, minimumY), max(minimumY, maximumY))

        toolbarPanel.setFrame(
            NSRect(x: x, y: y, width: width, height: height),
            display: true
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
