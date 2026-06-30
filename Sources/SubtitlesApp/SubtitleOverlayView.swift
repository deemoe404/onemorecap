@preconcurrency import Cocoa
import SubtitlesAppSupport

protocol SubtitleOverlayViewDelegate: AnyObject {
    func subtitleOverlayViewDidEnterInteractiveArea(_ view: SubtitleOverlayView)
    func subtitleOverlayViewDidExitInteractiveArea(_ view: SubtitleOverlayView)
    func subtitleOverlayViewDidLayout(_ view: SubtitleOverlayView)
    func subtitleOverlayView(_ view: SubtitleOverlayView, didRequestLoadURL url: URL)
    func subtitleOverlayViewDidBeginResizingContainer(_ view: SubtitleOverlayView)
    func subtitleOverlayView(_ view: SubtitleOverlayView, didResizeContainer edge: SubtitleContainerResizeEdge, by delta: CGFloat)
    func subtitleOverlayViewDidEndResizingContainer(_ view: SubtitleOverlayView)
}

final class SubtitleOverlayView: NSView, SubtitleContainerChromeViewDelegate {
    private enum TrackingRole: String {
        case subtitle
        case containerChrome
    }

    private static let trackingRoleKey = "SubtitleOverlayTrackingRole"
    weak var delegate: SubtitleOverlayViewDelegate?

    private static let placeholderText = "Drop SRT or VTT subtitle here"

    var subtitleText: String = placeholderText {
        didSet {
            updateSubtitleText()
        }
    }

    private let subtitleBackdropView = NSView()
    private let subtitleLabel = NSTextField(labelWithString: placeholderText)
    private let subtitleContainerChromeView = SubtitleContainerChromeView()

    private var captionAppearance = SystemCaptionAppearance.current()
    private var captionAppearanceMonitor: SystemCaptionAppearanceMonitor?
    private var isReportingCaptions = true
    private var isContainerChromeVisible = false
    private var isContainerResizeActive = false
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
        rebuildTrackingAreas()
    }

    override func layout() {
        super.layout()
        rebuildTrackingAreas()
        delegate?.subtitleOverlayViewDidLayout(self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if isContainerChromeInteractive, subtitleContainerChromeView.frame.contains(point) {
            let chromePoint = convert(point, to: subtitleContainerChromeView)
            if let chromeHit = subtitleContainerChromeView.hitTest(chromePoint) {
                return chromeHit
            }
        }

        return isInteractivePoint(point) ? self : nil
    }

    override func mouseEntered(with event: NSEvent) {
        guard let role = trackingRole(from: event) else {
            return
        }

        switch role {
        case .subtitle:
            delegate?.subtitleOverlayViewDidEnterInteractiveArea(self)
        case .containerChrome:
            delegate?.subtitleOverlayViewDidEnterInteractiveArea(self)
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard let point = currentMouseLocationInView(), isInteractivePoint(point) else {
            delegate?.subtitleOverlayViewDidExitInteractiveArea(self)
            return
        }
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

    func setContainerChromeVisible(_ visible: Bool, animated: Bool) {
        guard visible != isContainerChromeVisible else {
            rebuildTrackingAreas()
            return
        }

        isContainerChromeVisible = visible

        if visible {
            subtitleContainerChromeView.isHidden = false
            subtitleContainerChromeView.alphaValue = animated ? 0 : 1
        }

        rebuildTrackingAreas()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.12 : 0
            subtitleContainerChromeView.animator().alphaValue = visible ? 1 : 0
        } completionHandler: { [weak self] in
            guard let self else {
                return
            }
            self.subtitleContainerChromeView.isHidden = !self.isContainerChromeVisible
            self.rebuildTrackingAreas()
        }
    }

    func subtitleContainerChromeViewDidBeginDragging(_ view: SubtitleContainerChromeView) {
        isContainerResizeActive = true
        delegate?.subtitleOverlayViewDidBeginResizingContainer(self)
    }

    func subtitleContainerChromeView(_ view: SubtitleContainerChromeView, didDrag edge: SubtitleContainerResizeEdge, by delta: CGFloat) {
        delegate?.subtitleOverlayView(self, didResizeContainer: edge, by: delta)
    }

    func subtitleContainerChromeViewDidEndDragging(_ view: SubtitleContainerChromeView) {
        isContainerResizeActive = false
        delegate?.subtitleOverlayViewDidEndResizingContainer(self)
        rebuildTrackingAreas()
    }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 0
        registerForDraggedTypes([.fileURL])

        subtitleContainerChromeView.translatesAutoresizingMaskIntoConstraints = false
        subtitleContainerChromeView.alphaValue = 0
        subtitleContainerChromeView.isHidden = true
        subtitleContainerChromeView.delegate = self

        subtitleBackdropView.translatesAutoresizingMaskIntoConstraints = false
        subtitleBackdropView.wantsLayer = true
        subtitleBackdropView.layer?.backgroundColor = captionAppearance.windowColor.cgColor
        subtitleBackdropView.layer?.cornerRadius = captionAppearance.windowCornerRadius

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.alignment = .center
        subtitleLabel.maximumNumberOfLines = 3
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(subtitleContainerChromeView)
        addSubview(subtitleBackdropView)
        subtitleBackdropView.addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            subtitleContainerChromeView.centerXAnchor.constraint(equalTo: centerXAnchor),
            subtitleContainerChromeView.centerYAnchor.constraint(equalTo: subtitleBackdropView.centerYAnchor),
            subtitleContainerChromeView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            subtitleContainerChromeView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            subtitleContainerChromeView.heightAnchor.constraint(equalTo: subtitleBackdropView.heightAnchor, constant: 24),

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
        if isContainerChromeInteractive {
            addTrackingArea(for: subtitleContainerChromeView.frame, role: .containerChrome)
        }
    }

    private func addTrackingArea(for rect: NSRect, role: TrackingRole) {
        guard rect.width > 0, rect.height > 0 else {
            return
        }

        let trackingArea = NSTrackingArea(
            rect: rect,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: [Self.trackingRoleKey: role.rawValue]
        )
        addTrackingArea(trackingArea)
        trackingAreaRefs.append(trackingArea)
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

        if isContainerChromeInteractive, subtitleContainerChromeView.frame.contains(point) {
            return true
        }

        return false
    }

    private var isContainerChromeInteractive: Bool {
        isContainerChromeVisible || isContainerResizeActive
    }

    func containsScreenPointInInteractiveArea(_ screenPoint: NSPoint) -> Bool {
        guard let window else {
            return false
        }

        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let point = convert(windowPoint, from: nil)
        return isInteractivePoint(point)
    }

    func subtitleBackdropFrameInScreen() -> NSRect? {
        guard let window else {
            return nil
        }

        let windowFrame = convert(subtitleBackdropView.frame, to: nil)
        return window.convertToScreen(windowFrame)
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
