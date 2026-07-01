@preconcurrency import Cocoa
import Combine
import SwiftUI

protocol SubtitleToolbarViewDelegate: AnyObject {
    func subtitleToolbarViewDidEnter(_ view: SubtitleToolbarView)
    func subtitleToolbarViewDidExit(_ view: SubtitleToolbarView)
    func subtitleToolbarView(_ view: SubtitleToolbarView, didAdjustOffsetBy delta: TimeInterval)
    func subtitleToolbarViewDidRequestAppleTVCalibration(_ view: SubtitleToolbarView)
}

final class SubtitleToolbarView: NSView {
    static let glassRenderPadding: CGFloat = 8

    weak var delegate: SubtitleToolbarViewDelegate?

    private let model = SubtitleToolbarModel()
    private var hostingView: NSHostingView<SubtitleToolbarContentView>?
    private var trackingAreaRef: NSTrackingArea?

    override var intrinsicContentSize: NSSize {
        guard let hostingView else {
            let padding = Self.glassRenderPadding * 2
            return NSSize(width: 280 + padding, height: 38 + padding)
        }
        return hostingView.fittingSize
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseEntered(with event: NSEvent) {
        delegate?.subtitleToolbarViewDidEnter(self)
    }

    override func mouseExited(with event: NSEvent) {
        delegate?.subtitleToolbarViewDidExit(self)
    }

    func setPlaybackState(isPlaying _: Bool, time: TimeInterval, offset: TimeInterval, sourceLabel: String) {
        model.playbackTime = time
        model.offset = offset
        model.sourceLabel = sourceLabel
        invalidateIntrinsicContentSize()
    }

    private func setupView() {
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = [.width, .height]

        model.adjustOffset = { [weak self] delta in
            guard let self else {
                return
            }
            delegate?.subtitleToolbarView(self, didAdjustOffsetBy: delta)
        }
        model.requestAppleTVCalibration = { [weak self] in
            guard let self else {
                return
            }
            delegate?.subtitleToolbarViewDidRequestAppleTVCalibration(self)
        }

        let contentView = FirstMouseHostingView(rootView: SubtitleToolbarContentView(model: model))
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.setContentHuggingPriority(.required, for: .horizontal)
        contentView.setContentHuggingPriority(.required, for: .vertical)
        addSubview(contentView)
        hostingView = contentView

        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

private final class SubtitleToolbarModel: ObservableObject {
    @Published var playbackTime: TimeInterval = 0
    @Published var offset: TimeInterval = 0
    @Published var sourceLabel = "Manual"
    @Published var syncTarget: SubtitleToolbarSyncTarget = .appleTV

    var adjustOffset: ((TimeInterval) -> Void)?
    var requestAppleTVCalibration: (() -> Void)?

    var statusKind: SubtitleToolbarStatusKind {
        SubtitleToolbarStatusKind(sourceLabel: sourceLabel)
    }

    var playbackTimeText: String {
        formatTime(playbackTime)
    }

    var offsetText: String {
        formatOffset(offset)
    }

    var syncTargetHelp: String {
        "Select sync target"
    }

    var syncActionHelp: String {
        "Sync with \(syncTarget.displayName)"
    }

    func requestCurrentTargetSync() {
        switch syncTarget {
        case .appleTV:
            requestAppleTVCalibration?()
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let totalSeconds = Int(max(0, time))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func formatOffset(_ offset: TimeInterval) -> String {
        String(format: "%+.1fs", offset)
    }
}

private enum SubtitleToolbarStatusKind {
    case manual
    case appleTVCalibrated
    case unknown

    init(sourceLabel: String) {
        switch sourceLabel {
        case "Manual":
            self = .manual
        case "TV calibrated":
            self = .appleTVCalibrated
        default:
            self = .unknown
        }
    }

    var symbolName: String {
        switch self {
        case .manual:
            return "hand.tap.fill"
        case .appleTVCalibrated:
            return "appletv.fill"
        case .unknown:
            return "questionmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .manual:
            return .yellow
        case .appleTVCalibrated:
            return .green
        case .unknown:
            return .gray
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .manual:
            return "Manual playback"
        case .appleTVCalibrated:
            return "Apple TV calibrated playback"
        case .unknown:
            return "Unknown playback source"
        }
    }
}

private enum SubtitleToolbarSyncTarget: CaseIterable, Hashable, Identifiable {
    case appleTV

    var id: Self { self }

    var displayName: String {
        switch self {
        case .appleTV:
            return "Apple TV"
        }
    }

    var symbolName: String {
        switch self {
        case .appleTV:
            return "appletv.fill"
        }
    }
}

private struct SubtitleToolbarContentView: View {
    private static let bubbleHeight: CGFloat = 44
    private static let syncActionWidth: CGFloat = 44
    private static let syncTargetWidth: CGFloat = 56

    @ObservedObject var model: SubtitleToolbarModel
    @State private var isSyncActionHovered = false

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 10) {
                statusView
                    .frame(maxWidth: 420, alignment: .leading)
                    .frame(height: Self.bubbleHeight)
                    .padding(.horizontal, 12)
                    .glassEffect(.regular.interactive(), in: Capsule())

                syncControl
                    .layoutPriority(1)
            }
        }
        .padding(SubtitleToolbarView.glassRenderPadding)
        .fixedSize(horizontal: true, vertical: true)
        .environment(\.controlActiveState, .active)
    }

    private var syncControl: some View {
        HStack(spacing: 0) {
            Button {
                model.requestCurrentTargetSync()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: Self.syncActionWidth, height: Self.bubbleHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SplitPillActionButtonStyle(isHovered: isSyncActionHovered))
            .onHover { isSyncActionHovered = $0 }
            .help(model.syncActionHelp)
            .accessibilityLabel(Text(model.syncActionHelp))

            Divider()
                .frame(height: 22)

            Menu {
                Picker("Sync Target", selection: $model.syncTarget) {
                    ForEach(SubtitleToolbarSyncTarget.allCases) { target in
                        Label(target.displayName, systemImage: target.symbolName)
                            .tag(target)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: model.syncTarget.symbolName)
                        .font(.system(size: 14, weight: .semibold))

                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: Self.syncTargetWidth, height: Self.bubbleHeight)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .help(model.syncTargetHelp)
            .accessibilityLabel(Text("Sync target"))
            .accessibilityValue(Text(model.syncTarget.displayName))
        }
        .frame(height: Self.bubbleHeight)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    private struct SplitPillActionButtonStyle: ButtonStyle {
        private static let highlightSize: CGFloat = 32

        let isHovered: Bool

        func makeBody(configuration: Configuration) -> some View {
            let fillOpacity = configuration.isPressed ? 0.18 : isHovered ? 0.12 : 0
            let strokeOpacity = configuration.isPressed ? 0.22 : isHovered ? 0.16 : 0

            return configuration.label
                .background {
                    Circle()
                        .fill(.primary.opacity(fillOpacity))
                        .frame(width: Self.highlightSize, height: Self.highlightSize)
                }
                .overlay {
                    Circle()
                        .stroke(.primary.opacity(strokeOpacity), lineWidth: 0.75)
                        .frame(width: Self.highlightSize, height: Self.highlightSize)
                }
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.easeOut(duration: 0.12), value: isHovered)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }

    private var statusView: some View {
        HStack(spacing: 6) {
            Image(systemName: model.statusKind.symbolName)
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(model.statusKind.tint)
                .accessibilityLabel(Text(model.statusKind.accessibilityLabel))
                .help(model.statusKind.accessibilityLabel)

            Text(model.playbackTimeText)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)

            Text(model.offsetText)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Stepper(
                "Subtitle offset",
                onIncrement: {
                    model.adjustOffset?(0.5)
                },
                onDecrement: {
                    model.adjustOffset?(-0.5)
                }
            )
            .labelsHidden()
            .controlSize(.mini)
            .fixedSize()
            .help("Adjust subtitle offset by 0.5 seconds")
            .accessibilityLabel(Text("Adjust subtitle offset"))
            .accessibilityValue(Text(model.offsetText))
        }
    }
}
