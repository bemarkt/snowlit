#if os(iOS)
import SnowlitCore
import UIKit

/// Bounded layout experiment, not the production chapter/window/pagination implementation.
@MainActor
final class ProbeViewport: UIViewController {
    enum Failure: Error { case textKit2Unavailable, positionUnavailable }

    /// Ephemeral display state. Only the semantic anchor belongs in persistent reading state.
    struct VisiblePosition {
        let anchor: ProbeTextAnchor
        let verticalOffset: CGFloat
    }

    let projection: ProbeTextProjection
    let textView = UITextView(usingTextLayoutManager: true)
    private(set) var commentButtons: [String: UIButton] = [:]
    private(set) var lastCommentTarget: String?
    private var renderOffsets: [String: [Int: Int]] = [:]
    private var textCoordinateView: UIView {
        let input: any UITextInput = textView
        return input.textInputView ?? textView
    }

    init(document: ProbeDocument) {
        projection = ProbeTextProjection(document: document)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .systemBackground
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 24, right: 68)
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    /// Explicitly lays out the whole small sample. This must not be treated as long-book virtualization.
    func render(fontSize: CGFloat, attachmentHeight: CGFloat? = nil,
                preserving anchor: ProbeTextAnchor? = nil) throws {
        loadViewIfNeeded()
        for button in commentButtons.values { button.removeFromSuperview() }
        commentButtons.removeAll()
        renderOffsets.removeAll()
        let attributed = NSMutableAttributedString(string: "")
        for (index, paragraph) in projection.document.paragraphs.enumerated() {
            if index > 0 { attributed.append(NSAttributedString(string: "\n")) }
            var logical = 0
            var offsets = [0: attributed.length]
            for run in paragraph.runs {
                switch run {
                case .text(let text):
                    for offset in 0...text.utf16.count { offsets[logical + offset] = attributed.length + offset }
                    attributed.append(NSAttributedString(string: text))
                    logical += text.utf16.count
                case .image(let image):
                    switch image.role {
                    case .illustration:
                        if let attachmentHeight {
                            let attachment = NSTextAttachment()
                            attachment.image = UIImage(systemName: "photo")
                            attachment.bounds = CGRect(x: 0, y: 0, width: 160, height: attachmentHeight)
                            attributed.append(NSAttributedString(attachment: attachment))
                            offsets[logical] = attributed.length
                        }
                    case .comment(let paragraphID, _):
                        let button = UIButton(type: .system)
                        button.setImage(UIImage(systemName: "text.bubble"), for: .normal)
                        button.accessibilityLabel = "段落评论"
                        button.accessibilityIdentifier = "probe-comment-\(paragraphID)"
                        button.addAction(UIAction { [weak self] _ in self?.lastCommentTarget = paragraphID }, for: .touchUpInside)
                        commentButtons[paragraphID] = button
                    }
                }
            }
            renderOffsets[paragraph.id] = offsets
        }
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 32 // Leaves at least 8pt between this sample's 44pt markers.
        attributed.addAttributes([.font: UIFont.systemFont(ofSize: fontSize),
                                  .foregroundColor: UIColor.label, .paragraphStyle: style],
                                 range: NSRange(location: 0, length: attributed.length))
        textView.attributedText = attributed
        view.layoutIfNeeded()
        guard let layout = textView.textLayoutManager, let content = layout.textContentManager else {
            throw Failure.textKit2Unavailable
        }
        layout.ensureLayout(for: content.documentRange)
        for (paragraphID, button) in commentButtons {
            let target = ProbeTextAnchor(documentID: projection.document.id, revision: projection.document.revision,
                                         paragraphID: paragraphID, utf16Offset: 0)
            let rectangle = try caret(at: target)
            button.frame = CGRect(x: textView.bounds.width - 56, y: max(16, rectangle.midY - 22), width: 44, height: 44)
            textView.addSubview(button)
        }
        if let anchor { try restore(anchor) }
    }

    func layoutOffset(of anchor: ProbeTextAnchor) throws -> Int {
        _ = try projection.utf16Offset(of: anchor)
        guard let offset = renderOffsets[anchor.paragraphID]?[anchor.utf16Offset] else { throw Failure.positionUnavailable }
        return offset
    }

    func caret(at anchor: ProbeTextAnchor) throws -> CGRect {
        let offset = try layoutOffset(of: anchor)
        guard let position = textView.position(from: textView.beginningOfDocument, offset: offset) else {
            throw Failure.positionUnavailable
        }
        return textView.caretRect(for: position)
    }

    func restore(_ anchor: ProbeTextAnchor) throws {
        let offset = try layoutOffset(of: anchor)
        textView.selectedRange = NSRange(location: offset, length: 0)
        textView.scrollRangeToVisible(textView.selectedRange)
    }

    func selectedAnchor() throws -> ProbeTextAnchor {
        try anchor(atLayoutOffset: textView.selectedRange.location)
    }

    func captureVisiblePosition() throws -> VisiblePosition {
        view.layoutIfNeeded()
        let point = CGPoint(x: textView.bounds.minX + textView.textContainerInset.left
                                + textView.textContainer.lineFragmentPadding + 1,
                            y: textView.bounds.minY + textView.adjustedContentInset.top + 1)
        let inputPoint = textCoordinateView.convert(point, from: textView)
        guard let position = textView.closestPosition(to: inputPoint) else { throw Failure.positionUnavailable }
        let offset = textView.offset(from: textView.beginningOfDocument, to: position)
        let anchor = try anchor(atLayoutOffset: offset)
        return VisiblePosition(anchor: anchor, verticalOffset: try visibleOffset(of: anchor))
    }

    func visibleOffset(of anchor: ProbeTextAnchor) throws -> CGFloat {
        let rectangle = try caretInViewport(at: anchor)
        return rectangle.minY - textView.frame.minY
    }

    func caretInViewport(at anchor: ProbeTextAnchor) throws -> CGRect {
        view.convert(try caret(at: anchor), from: textCoordinateView)
    }

    func restoreVisible(_ position: VisiblePosition) throws {
        let delta = try visibleOffset(of: position.anchor) - position.verticalOffset
        let insets = textView.adjustedContentInset
        let minimum = -insets.top
        let maximum = max(minimum, textView.contentSize.height - textView.bounds.height + insets.bottom)
        let offset = min(maximum, max(minimum, textView.contentOffset.y + delta))
        textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: offset), animated: false)
        textView.layoutIfNeeded()
    }

    func render(fontSize: CGFloat, attachmentHeight: CGFloat? = nil,
                maintaining position: VisiblePosition) throws {
        try render(fontSize: fontSize, attachmentHeight: attachmentHeight)
        try restoreVisible(position)
    }

    private func anchor(atLayoutOffset offset: Int) throws -> ProbeTextAnchor {
        for paragraph in projection.document.paragraphs {
            if let logical = renderOffsets[paragraph.id]?.first(where: { $0.value == offset })?.key {
                let anchor = ProbeTextAnchor(documentID: projection.document.id, revision: projection.document.revision,
                                             paragraphID: paragraph.id, utf16Offset: logical)
                _ = try projection.utf16Offset(of: anchor)
                return anchor
            }
        }
        throw Failure.positionUnavailable
    }
}
#endif
