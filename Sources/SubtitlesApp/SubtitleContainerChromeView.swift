@preconcurrency import Cocoa
import SwiftUI

enum SubtitleContainerResizeEdge {
    case left
    case right
}

protocol SubtitleContainerChromeViewDelegate: AnyObject {
    func subtitleContainerChromeViewDidBeginDragging(_ view: SubtitleContainerChromeView)
    func subtitleContainerChromeView(_ view: SubtitleContainerChromeView, didDrag edge: SubtitleContainerResizeEdge, by delta: CGFloat)
    func subtitleContainerChromeViewDidEndDragging(_ view: SubtitleContainerChromeView)
}

final class SubtitleContainerChromeView: NSView {
    weak var delegate: SubtitleContainerChromeViewDelegate?

    private static let handleHitWidth: CGFloat = 56

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard resizeEdge(for: point) != nil else {
            return nil
        }
        return super.hitTest(point) ?? self
    }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        let contentView = NSHostingView(
            rootView: SubtitleContainerChromeContentView(
                beginDragging: { [weak self] in
                    guard let self else {
                        return
                    }
                    delegate?.subtitleContainerChromeViewDidBeginDragging(self)
                },
                drag: { [weak self] edge, delta in
                    guard let self else {
                        return
                    }
                    delegate?.subtitleContainerChromeView(self, didDrag: edge, by: delta)
                },
                endDragging: { [weak self] in
                    guard let self else {
                        return
                    }
                    delegate?.subtitleContainerChromeViewDidEndDragging(self)
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

    private func resizeEdge(for point: NSPoint) -> SubtitleContainerResizeEdge? {
        guard bounds.contains(point) else {
            return nil
        }

        if point.x <= Self.handleHitWidth {
            return .left
        }

        if point.x >= bounds.maxX - Self.handleHitWidth {
            return .right
        }

        return nil
    }
}

private struct SubtitleContainerChromeContentView: View {
    let beginDragging: () -> Void
    let drag: (SubtitleContainerResizeEdge, CGFloat) -> Void
    let endDragging: () -> Void

    var body: some View {
        GlassEffectContainer {
            HStack {
                ResizeHandle(
                    edge: .left,
                    beginDragging: beginDragging,
                    drag: drag,
                    endDragging: endDragging
                )

                Spacer(minLength: 24)

                ResizeHandle(
                    edge: .right,
                    beginDragging: beginDragging,
                    drag: drag,
                    endDragging: endDragging
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .environment(\.controlActiveState, .active)
    }
}

private struct ResizeHandle: View {
    let edge: SubtitleContainerResizeEdge
    let beginDragging: () -> Void
    let drag: (SubtitleContainerResizeEdge, CGFloat) -> Void
    let endDragging: () -> Void

    @State private var lastTranslation: CGFloat = 0
    @State private var isDragging = false

    var body: some View {
        Image(systemName: "arrow.left.and.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 34, height: 24)
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
