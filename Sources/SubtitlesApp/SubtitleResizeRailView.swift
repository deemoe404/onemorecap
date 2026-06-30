@preconcurrency import Cocoa
import SwiftUI

enum SubtitleResizeRailEdge {
    case left
    case right
}

protocol SubtitleResizeRailViewDelegate: AnyObject {
    func subtitleResizeRailViewDidEnter(_ view: SubtitleResizeRailView)
    func subtitleResizeRailViewDidExit(_ view: SubtitleResizeRailView)
    func subtitleResizeRailViewDidBeginDragging(_ view: SubtitleResizeRailView)
    func subtitleResizeRailView(_ view: SubtitleResizeRailView, didDrag edge: SubtitleResizeRailEdge, by delta: CGFloat)
    func subtitleResizeRailViewDidEndDragging(_ view: SubtitleResizeRailView)
}

final class SubtitleResizeRailView: NSView {
    weak var delegate: SubtitleResizeRailViewDelegate?

    private var trackingAreaRef: NSTrackingArea?

    override var intrinsicContentSize: NSSize {
        NSSize(width: 360, height: 34)
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

    override func mouseEntered(with event: NSEvent) {
        delegate?.subtitleResizeRailViewDidEnter(self)
    }

    override func mouseExited(with event: NSEvent) {
        delegate?.subtitleResizeRailViewDidExit(self)
    }

    private func setupView() {
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = [.width, .height]

        let contentView = NSHostingView(
            rootView: SubtitleResizeRailContentView(
                beginDragging: { [weak self] in
                    guard let self else {
                        return
                    }
                    delegate?.subtitleResizeRailViewDidBeginDragging(self)
                },
                drag: { [weak self] edge, delta in
                    guard let self else {
                        return
                    }
                    delegate?.subtitleResizeRailView(self, didDrag: edge, by: delta)
                },
                endDragging: { [weak self] in
                    guard let self else {
                        return
                    }
                    delegate?.subtitleResizeRailViewDidEndDragging(self)
                }
            )
        )
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)

        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}

private struct SubtitleResizeRailContentView: View {
    let beginDragging: () -> Void
    let drag: (SubtitleResizeRailEdge, CGFloat) -> Void
    let endDragging: () -> Void

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 8) {
                ResizeHandle(
                    edge: .left,
                    beginDragging: beginDragging,
                    drag: drag,
                    endDragging: endDragging
                )

                Capsule()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(height: 4)
                    .frame(maxWidth: .infinity)

                ResizeHandle(
                    edge: .right,
                    beginDragging: beginDragging,
                    drag: drag,
                    endDragging: endDragging
                )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        .frame(minWidth: 220, maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.controlActiveState, .active)
    }
}

private struct ResizeHandle: View {
    let edge: SubtitleResizeRailEdge
    let beginDragging: () -> Void
    let drag: (SubtitleResizeRailEdge, CGFloat) -> Void
    let endDragging: () -> Void

    @State private var lastTranslation: CGFloat = 0
    @State private var isDragging = false

    var body: some View {
        Image(systemName: "arrow.left.and.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 30, height: 20)
            .contentShape(Rectangle())
            .help(edge == .left ? "Drag to resize from the left" : "Drag to resize from the right")
            .accessibilityLabel(Text(edge == .left ? "Resize subtitle width from the left" : "Resize subtitle width from the right"))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            beginDragging()
                        }

                        let delta = value.translation.width - lastTranslation
                        lastTranslation = value.translation.width
                        drag(edge, delta)
                    }
                    .onEnded { _ in
                        lastTranslation = 0
                        isDragging = false
                        endDragging()
                    }
            )
    }
}
