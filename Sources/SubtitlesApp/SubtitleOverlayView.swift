@preconcurrency import Cocoa
import SubtitlesAppSupport

protocol SubtitleOverlayViewDelegate: AnyObject {
    func subtitleOverlayViewDidRequestPlayPause(_ view: SubtitleOverlayView)
    func subtitleOverlayViewDidRequestReset(_ view: SubtitleOverlayView)
    func subtitleOverlayView(_ view: SubtitleOverlayView, didAdjustOffsetBy delta: TimeInterval)
    func subtitleOverlayViewDidRequestAppleTVCalibration(_ view: SubtitleOverlayView)
    func subtitleOverlayViewDidRequestCaptionSettings(_ view: SubtitleOverlayView)
    func subtitleOverlayView(_ view: SubtitleOverlayView, didRequestLoadURL url: URL)
    func subtitleOverlayViewDidRequestClose(_ view: SubtitleOverlayView)
    func subtitleOverlayView(_ view: SubtitleOverlayView, didRequestScale factor: CGFloat)
}

final class SubtitleOverlayView: NSView {
    private enum TrackingRole: String {
        case subtitle
        case toolbar
        case metadata
    }

    private static let trackingRoleKey = "SubtitleOverlayTrackingRole"
    weak var delegate: SubtitleOverlayViewDelegate?

    private static let placeholderText = "Drop SRT or VTT subtitle here"

    var subtitleText: String = placeholderText {
        didSet {
            updateSubtitleText()
        }
    }

    var loadedFileName: String? {
        didSet {
            updateMetadata()
        }
    }

    private let subtitleBackdropView = NSView()
    private let subtitleLabel = NSTextField(labelWithString: placeholderText)
    private let metadataLabel = NSTextField(labelWithString: "00:00.0  Offset +0.0s")
    private let toolbarContainerView = NSView()
    private let controlsStack = NSStackView()
    private let playPauseButton = NSButton(title: "Play", target: nil, action: nil)

    private var captionAppearance = SystemCaptionAppearance.current()
    private var captionAppearanceMonitor: SystemCaptionAppearanceMonitor?
    private var playbackTime: TimeInterval = 0
    private var offset: TimeInterval = 0
    private var isPlaying = false
    private var sourceLabel = "Manual"
    private var isReportingCaptions = true
    private var lastReportedCaptionText: String?
    private var trackingAreaRefs: [NSTrackingArea] = []
    private var controlsAreVisible = false

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
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isInteractivePoint(point) else {
            return nil
        }

        if controlsAreVisible, toolbarContainerView.frame.contains(point) {
            return super.hitTest(point)
        }

        return self
    }

    override func mouseEntered(with event: NSEvent) {
        guard let role = trackingRole(from: event) else {
            return
        }

        switch role {
        case .subtitle:
            setControlsVisible(true)
        case .toolbar, .metadata:
            if controlsAreVisible {
                setControlsVisible(true)
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard let point = currentMouseLocationInView(), isInteractivePoint(point) else {
            setControlsVisible(false)
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

    func setPlaybackState(isPlaying: Bool, time: TimeInterval, offset: TimeInterval, sourceLabel: String = "Manual") {
        self.isPlaying = isPlaying
        self.playbackTime = time
        self.offset = offset
        self.sourceLabel = sourceLabel
        playPauseButton.title = isPlaying ? "Pause" : "Play"
        updateMetadata()
    }

    func setCaptionReportingEnabled(_ enabled: Bool) {
        isReportingCaptions = enabled
        reportDisplayedCaptions(force: true)
    }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 0
        registerForDraggedTypes([.fileURL])

        subtitleBackdropView.translatesAutoresizingMaskIntoConstraints = false
        subtitleBackdropView.wantsLayer = true
        subtitleBackdropView.layer?.backgroundColor = captionAppearance.windowColor.cgColor
        subtitleBackdropView.layer?.cornerRadius = captionAppearance.windowCornerRadius

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.alignment = .center
        subtitleLabel.maximumNumberOfLines = 3
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        metadataLabel.translatesAutoresizingMaskIntoConstraints = false
        metadataLabel.textColor = NSColor.white.withAlphaComponent(0.74)
        metadataLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        metadataLabel.alignment = .center
        metadataLabel.alphaValue = 0

        toolbarContainerView.translatesAutoresizingMaskIntoConstraints = false
        toolbarContainerView.wantsLayer = true
        toolbarContainerView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        toolbarContainerView.layer?.cornerRadius = 8
        toolbarContainerView.layer?.borderWidth = 1
        toolbarContainerView.layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
        toolbarContainerView.alphaValue = 0
        toolbarContainerView.isHidden = true

        controlsStack.translatesAutoresizingMaskIntoConstraints = false
        controlsStack.orientation = .horizontal
        controlsStack.alignment = .centerY
        controlsStack.distribution = .fill
        controlsStack.spacing = 8

        let controls = [
            makeButton("W-", action: #selector(decreaseWindowSize)),
            makeButton("W+", action: #selector(increaseWindowSize)),
            makeButton("-0.5s", action: #selector(decreaseOffset)),
            makeButton("+0.5s", action: #selector(increaseOffset)),
            makeButton("Captions", action: #selector(openCaptionSettings)),
            makeButton("Calibrate TV", action: #selector(calibrateAppleTV)),
            playPauseButton,
            makeButton("Reset", action: #selector(resetPlayback)),
            makeButton("Close", action: #selector(closePanel))
        ]

        playPauseButton.target = self
        playPauseButton.action = #selector(playPause)
        styleButton(playPauseButton)
        controls.forEach { controlsStack.addArrangedSubview($0) }

        addSubview(subtitleBackdropView)
        subtitleBackdropView.addSubview(subtitleLabel)
        addSubview(metadataLabel)
        addSubview(toolbarContainerView)
        toolbarContainerView.addSubview(controlsStack)

        NSLayoutConstraint.activate([
            subtitleBackdropView.centerXAnchor.constraint(equalTo: centerXAnchor),
            subtitleBackdropView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -6),
            subtitleBackdropView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            subtitleBackdropView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),

            subtitleLabel.leadingAnchor.constraint(equalTo: subtitleBackdropView.leadingAnchor, constant: 16),
            subtitleLabel.trailingAnchor.constraint(equalTo: subtitleBackdropView.trailingAnchor, constant: -16),
            subtitleLabel.topAnchor.constraint(equalTo: subtitleBackdropView.topAnchor, constant: 8),
            subtitleLabel.bottomAnchor.constraint(equalTo: subtitleBackdropView.bottomAnchor, constant: -8),

            metadataLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            metadataLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            metadataLabel.topAnchor.constraint(equalTo: subtitleBackdropView.bottomAnchor, constant: 8),

            toolbarContainerView.centerXAnchor.constraint(equalTo: subtitleBackdropView.centerXAnchor),
            toolbarContainerView.bottomAnchor.constraint(equalTo: subtitleBackdropView.topAnchor, constant: 4),
            toolbarContainerView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            toolbarContainerView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),

            controlsStack.leadingAnchor.constraint(equalTo: toolbarContainerView.leadingAnchor, constant: 8),
            controlsStack.trailingAnchor.constraint(equalTo: toolbarContainerView.trailingAnchor, constant: -8),
            controlsStack.topAnchor.constraint(equalTo: toolbarContainerView.topAnchor, constant: 4),
            controlsStack.bottomAnchor.constraint(equalTo: toolbarContainerView.bottomAnchor, constant: -4)
        ])

        updateSubtitleText()
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        styleButton(button)
        return button
    }

    private func styleButton(_ button: NSButton) {
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.setButtonType(.momentaryPushIn)
    }

    private func setControlsVisible(_ visible: Bool) {
        guard visible != controlsAreVisible else {
            return
        }

        controlsAreVisible = visible
        if visible {
            toolbarContainerView.isHidden = false
        }
        rebuildTrackingAreas()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            toolbarContainerView.animator().alphaValue = visible ? 1 : 0
            metadataLabel.animator().alphaValue = visible ? 1 : 0
        } completionHandler: { [weak self] in
            guard let self, !self.controlsAreVisible else {
                return
            }
            self.toolbarContainerView.isHidden = true
            self.rebuildTrackingAreas()
        }
    }

    private func rebuildTrackingAreas() {
        trackingAreaRefs.forEach { removeTrackingArea($0) }
        trackingAreaRefs.removeAll()

        addTrackingArea(for: subtitleBackdropView.frame, role: .subtitle)

        guard controlsAreVisible else {
            return
        }

        addTrackingArea(for: toolbarContainerView.frame, role: .toolbar)
        addTrackingArea(for: metadataInteractiveFrame, role: .metadata)
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

        guard controlsAreVisible else {
            return false
        }

        return toolbarContainerView.frame.contains(point) || metadataInteractiveFrame.contains(point)
    }

    private var metadataInteractiveFrame: NSRect {
        let size = metadataLabel.intrinsicContentSize
        guard size.width > 0, size.height > 0 else {
            return .zero
        }

        let width = min(metadataLabel.frame.width, size.width + 16)
        let height = min(metadataLabel.frame.height, size.height + 4)
        return NSRect(
            x: metadataLabel.frame.midX - width / 2,
            y: metadataLabel.frame.midY - height / 2,
            width: width,
            height: height
        )
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

    private func updateMetadata() {
        let file = loadedFileName.map { "  \($0)" } ?? ""
        metadataLabel.stringValue = "\(sourceLabel)  \(formatTime(playbackTime))  Offset \(formatOffset(offset))\(file)"
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let clamped = max(0, time)
        let minutes = Int(clamped) / 60
        let seconds = clamped.truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%04.1f", minutes, seconds)
    }

    private func formatOffset(_ offset: TimeInterval) -> String {
        String(format: "%+.1fs", offset)
    }

    private func firstSupportedURL(from pasteboard: NSPasteboard) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        return urls?.first { url in
            ["srt", "vtt", "webvtt"].contains(url.pathExtension.lowercased())
        }
    }

    @objc private func decreaseWindowSize() {
        delegate?.subtitleOverlayView(self, didRequestScale: 0.9)
    }

    @objc private func increaseWindowSize() {
        delegate?.subtitleOverlayView(self, didRequestScale: 1.1)
    }

    @objc private func decreaseOffset() {
        delegate?.subtitleOverlayView(self, didAdjustOffsetBy: -0.5)
    }

    @objc private func increaseOffset() {
        delegate?.subtitleOverlayView(self, didAdjustOffsetBy: 0.5)
    }

    @objc private func calibrateAppleTV() {
        delegate?.subtitleOverlayViewDidRequestAppleTVCalibration(self)
    }

    @objc private func openCaptionSettings() {
        delegate?.subtitleOverlayViewDidRequestCaptionSettings(self)
    }

    @objc private func playPause() {
        delegate?.subtitleOverlayViewDidRequestPlayPause(self)
    }

    @objc private func resetPlayback() {
        delegate?.subtitleOverlayViewDidRequestReset(self)
    }

    @objc private func closePanel() {
        delegate?.subtitleOverlayViewDidRequestClose(self)
    }
}
