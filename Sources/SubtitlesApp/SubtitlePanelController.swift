@preconcurrency import Cocoa
import SubtitleCore

protocol SubtitlePanelControllerDelegate: AnyObject {
    func subtitlePanelDidRequestPlayPause(_ panelController: SubtitlePanelController)
    func subtitlePanelDidRequestReset(_ panelController: SubtitlePanelController)
    func subtitlePanel(_ panelController: SubtitlePanelController, didAdjustOffsetBy delta: TimeInterval)
    func subtitlePanelDidRequestAppleTVCalibration(_ panelController: SubtitlePanelController)
    func subtitlePanelDidRequestCaptionSettings(_ panelController: SubtitlePanelController)
    func subtitlePanel(_ panelController: SubtitlePanelController, didRequestLoadURL url: URL)
    func subtitlePanelDidRequestClose(_ panelController: SubtitlePanelController)
}

final class SubtitlePanelController: NSObject, NSWindowDelegate, SubtitleOverlayViewDelegate {
    weak var delegate: SubtitlePanelControllerDelegate?

    private let panel: SubtitlePanel
    private let overlayView = SubtitleOverlayView()

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

        overlayView.delegate = self
    }

    func show() {
        if !panel.isVisible {
            panel.setFrame(Self.defaultFrame(), display: false)
        }
        overlayView.setCaptionReportingEnabled(true)
        panel.orderFrontRegardless()
    }

    func hide() {
        overlayView.setCaptionReportingEnabled(false)
        panel.orderOut(nil)
    }

    func showMessage(_ message: String) {
        overlayView.subtitleText = message
    }

    func setPlaybackState(isPlaying: Bool, time: TimeInterval, offset: TimeInterval, sourceLabel: String = "Manual") {
        overlayView.setPlaybackState(isPlaying: isPlaying, time: time, offset: offset, sourceLabel: sourceLabel)
    }

    func setLoadedFileName(_ fileName: String) {
        overlayView.loadedFileName = fileName
    }

    func windowWillClose(_ notification: Notification) {
        delegate?.subtitlePanelDidRequestClose(self)
    }

    func subtitleOverlayViewDidRequestPlayPause(_ view: SubtitleOverlayView) {
        delegate?.subtitlePanelDidRequestPlayPause(self)
    }

    func subtitleOverlayViewDidRequestReset(_ view: SubtitleOverlayView) {
        delegate?.subtitlePanelDidRequestReset(self)
    }

    func subtitleOverlayView(_ view: SubtitleOverlayView, didAdjustOffsetBy delta: TimeInterval) {
        delegate?.subtitlePanel(self, didAdjustOffsetBy: delta)
    }

    func subtitleOverlayViewDidRequestAppleTVCalibration(_ view: SubtitleOverlayView) {
        delegate?.subtitlePanelDidRequestAppleTVCalibration(self)
    }

    func subtitleOverlayViewDidRequestCaptionSettings(_ view: SubtitleOverlayView) {
        delegate?.subtitlePanelDidRequestCaptionSettings(self)
    }

    func subtitleOverlayView(_ view: SubtitleOverlayView, didRequestLoadURL url: URL) {
        delegate?.subtitlePanel(self, didRequestLoadURL: url)
    }

    func subtitleOverlayViewDidRequestClose(_ view: SubtitleOverlayView) {
        hide()
        delegate?.subtitlePanelDidRequestClose(self)
    }

    func subtitleOverlayView(_ view: SubtitleOverlayView, didRequestScale factor: CGFloat) {
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
