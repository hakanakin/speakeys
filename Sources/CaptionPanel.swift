import AppKit

/// The live transcript bubble shown beside the orb while dictating.
final class CaptionPanel {
    private let panel = NSPanel.overlay()
    private let label = NSTextField(labelWithString: "")

    private enum Metrics {
        static let maxWidth: CGFloat = 420
        static let minWidth: CGFloat = 120
        static let horizontalPadding: CGFloat = 14
        static let verticalPadding: CGFloat = 10
        static let maxLines = 3
        /// Overlap with the orb's (mostly transparent) window so the bubble sits close to the orb.
        static let orbOverlap: CGFloat = 8
    }

    init() {
        panel.hasShadow = true

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        panel.contentView = background

        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.maximumNumberOfLines = Metrics.maxLines
        label.lineBreakMode = .byTruncatingHead   // keep the newest words visible
        label.cell?.truncatesLastVisibleLine = true
        background.addSubview(label)
    }

    /// Shows `text` (or a "Listening…" placeholder) beside `orbFrame`, on the side facing the screen center.
    func show(_ text: String, beside orbFrame: NSRect) {
        let isPlaceholder = text.isEmpty
        label.stringValue = isPlaceholder ? "Listening…" : text
        label.textColor = isPlaceholder ? .secondaryLabelColor : .labelColor

        let textWidth = Metrics.maxWidth - 2 * Metrics.horizontalPadding
        label.preferredMaxLayoutWidth = textWidth
        let fitted = label.sizeThatFits(NSSize(width: textWidth, height: .greatestFiniteMagnitude))
        let lineHeight = label.font.map { ceil($0.ascender - $0.descender + $0.leading) } ?? 18
        let textHeight = min(ceil(fitted.height), lineHeight * CGFloat(Metrics.maxLines))
        let width = min(Metrics.maxWidth, max(Metrics.minWidth, ceil(fitted.width) + 2 * Metrics.horizontalPadding))
        let height = textHeight + 2 * Metrics.verticalPadding
        label.frame = NSRect(x: Metrics.horizontalPadding, y: Metrics.verticalPadding,
                             width: width - 2 * Metrics.horizontalPadding, height: textHeight)

        let screen = NSScreen.screens.first { $0.frame.intersects(orbFrame) }?.visibleFrame ?? orbFrame
        let x = orbFrame.midX > screen.midX
            ? orbFrame.minX - width + Metrics.orbOverlap
            : orbFrame.maxX - Metrics.orbOverlap
        panel.setFrame(NSRect(x: x, y: orbFrame.midY - height / 2, width: width, height: height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            // `show` may have run during the fade
            if panel.alphaValue == 0 { panel.orderOut(nil) }
        })
    }
}
