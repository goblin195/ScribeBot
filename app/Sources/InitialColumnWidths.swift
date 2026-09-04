import SwiftUI
import AppKit

/// HSplitView treats ideal widths as suggestions and may give the index its
/// minimum on launch. Set the native divider positions once, after layout;
/// subsequent dragging and window resizing remain entirely native.
struct InitialColumnWidths: NSViewRepresentable {
    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ nsView: Marker, context: Context) {}

    final class Marker: NSView {
        private var applied = false
        private var scheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            schedule()
        }

        override func layout() {
            super.layout()
            schedule()
        }

        private func schedule() {
            guard window != nil, !applied, !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                var ancestor = self.superview
                while let view = ancestor {
                    if let split = view as? NSSplitView, split.isVertical,
                       split.arrangedSubviews.count == 3, split.bounds.width > 0 {
                        let available = split.bounds.width - 2 * split.dividerThickness
                        // Keep the reader usable on smaller windows while aiming
                        // for the 320 / 440 point proportions in the design.
                        let sidebar = min(320.0, max(240.0, available - 440 - 360))
                        let index = min(440.0, max(268.0, available - sidebar - 360))
                        self.applied = true
                        split.setPosition(sidebar, ofDividerAt: 0)
                        split.setPosition(sidebar + split.dividerThickness + index, ofDividerAt: 1)
                        return
                    }
                    ancestor = view.superview
                }
            }
        }
    }
}
