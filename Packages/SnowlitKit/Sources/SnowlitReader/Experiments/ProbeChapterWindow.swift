#if os(iOS)
import SnowlitCore
import UIKit

/// Small resident-window experiment. It lays out its three chapters in full;
/// measurements here do not establish production long-book virtualization.
@MainActor
final class ProbeChapterWindow: UIViewController {
    struct Position {
        let anchor: ProbeTextAnchor
        let y: CGFloat
    }
    let textView = UITextView(usingTextLayoutManager: true)
    private(set) var projection: ProbeChapterProjection?
    private var inputCoordinateView: UIView {
        let input: any UITextInput = textView
        return input.textInputView ?? textView
    }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .systemBackground
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 24, right: 16)
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
        ])
    }

    func render(_ documents: [ProbeDocument], fontSize: CGFloat, maintaining position: Position? = nil) throws {
        let next = try ProbeChapterProjection(documents: documents)
        // Reject an evicted or stale anchor before changing the visible window.
        if let position { _ = try next.offset(of: position.anchor) }
        loadViewIfNeeded()
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 12
        textView.attributedText = NSAttributedString(string: next.text, attributes: [
            .font: UIFont.systemFont(ofSize: fontSize), .foregroundColor: UIColor.label, .paragraphStyle: style,
        ])
        projection = next
        view.layoutIfNeeded()
        guard let layout = textView.textLayoutManager, let content = layout.textContentManager else {
            throw ProbeViewport.Failure.textKit2Unavailable
        }
        layout.ensureLayout(for: content.documentRange)
        // Selection is not the reading location. This experiment keeps it collapsed.
        textView.selectedRange = NSRange(location: 0, length: 0)
        if let position { try restore(position) }
    }

    func visibleY(of anchor: ProbeTextAnchor) throws -> CGFloat {
        guard let projection else { throw ProbeViewport.Failure.positionUnavailable }
        let offset = try projection.offset(of: anchor)
        guard let position = textView.position(from: textView.beginningOfDocument, offset: offset) else {
            throw ProbeViewport.Failure.positionUnavailable
        }
        return view.convert(textView.caretRect(for: position), from: inputCoordinateView).minY - textView.frame.minY
    }

    func restore(_ position: Position) throws {
        let delta = try visibleY(of: position.anchor) - position.y
        let minimum = -textView.adjustedContentInset.top
        let maximum = max(minimum, textView.contentSize.height - textView.bounds.height + textView.adjustedContentInset.bottom)
        let y = min(maximum, max(minimum, textView.contentOffset.y + delta))
        textView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        textView.layoutIfNeeded()
    }

    func capture() throws -> Position {
        guard let projection else { throw ProbeViewport.Failure.positionUnavailable }
        let point = CGPoint(x: textView.bounds.minX + textView.textContainerInset.left
                                + textView.textContainer.lineFragmentPadding + 1,
                            y: textView.bounds.minY + textView.adjustedContentInset.top + 1)
        guard let position = textView.closestPosition(to: inputCoordinateView.convert(point, from: textView)) else {
            throw ProbeViewport.Failure.positionUnavailable
        }
        let anchor = try projection.anchor(at: textView.offset(from: textView.beginningOfDocument, to: position))
        return Position(anchor: anchor, y: try visibleY(of: anchor))
    }
}
#endif
