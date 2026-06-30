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
    weak var delegate: SubtitleOverlayViewDelegate?

    private static let placeholderText = "Drop SRT or VTT subtitle here"
    private static let visibleBorderColor = NSColor.white.withAlphaComponent(0.16).cgColor
    private static let hiddenBorderColor = NSColor.clear.cgColor

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

    private let subtitleLabel = NSTextField(labelWithString: placeholderText)
    private let metadataLabel = NSTextField(labelWithString: "00:00.0  Offset +0.0s")
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
    private var trackingAreaRef: NSTrackingArea?

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
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        setControlsVisible(true)
    }

    override func mouseExited(with event: NSEvent) {
        setControlsVisible(false)
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
        layer?.backgroundColor = captionAppearance.windowColor.cgColor
        layer?.cornerRadius = captionAppearance.windowCornerRadius
        layer?.borderWidth = 1
        layer?.borderColor = Self.hiddenBorderColor
        registerForDraggedTypes([.fileURL])

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.alignment = .center
        subtitleLabel.maximumNumberOfLines = 3
        subtitleLabel.lineBreakMode = .byWordWrapping

        metadataLabel.translatesAutoresizingMaskIntoConstraints = false
        metadataLabel.textColor = NSColor.white.withAlphaComponent(0.74)
        metadataLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        metadataLabel.alignment = .center
        metadataLabel.alphaValue = 0

        controlsStack.translatesAutoresizingMaskIntoConstraints = false
        controlsStack.orientation = .horizontal
        controlsStack.alignment = .centerY
        controlsStack.distribution = .fill
        controlsStack.spacing = 8
        controlsStack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        controlsStack.isHidden = true

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

        addSubview(subtitleLabel)
        addSubview(metadataLabel)
        addSubview(controlsStack)

        NSLayoutConstraint.activate([
            subtitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            subtitleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            subtitleLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -6),

            metadataLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            metadataLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            metadataLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 8),

            controlsStack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            controlsStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            controlsStack.heightAnchor.constraint(equalToConstant: 28),
            controlsStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            controlsStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12)
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
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            layer?.borderColor = visible ? Self.visibleBorderColor : Self.hiddenBorderColor
            controlsStack.animator().isHidden = !visible
            metadataLabel.animator().alphaValue = visible ? 1 : 0
        }
    }

    private func startCaptionAppearanceMonitoring() {
        captionAppearanceMonitor = SystemCaptionAppearanceMonitor { [weak self] in
            self?.applyCaptionAppearance(SystemCaptionAppearance.current())
        }
    }

    private func applyCaptionAppearance(_ appearance: SystemCaptionAppearance) {
        captionAppearance = appearance
        layer?.backgroundColor = appearance.windowColor.cgColor
        layer?.cornerRadius = appearance.windowCornerRadius
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
