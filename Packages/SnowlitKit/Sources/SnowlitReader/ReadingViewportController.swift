#if os(iOS)
import SnowlitCore
import UIKit

/// A text-only TextKit 2 viewport. It owns at most three chapter projections;
/// source execution, persistence, images and navigation policy stay outside.
@MainActor
public final class ReadingViewportController: UIViewController, UITextViewDelegate {
    public enum Failure: Error { case unavailableLayout, unavailablePosition, unsettledPosition }
    public struct VisiblePosition {
        public let anchor: ReadingPosition
        public let y: CGFloat
        public init(anchor: ReadingPosition, y: CGFloat) { self.anchor = anchor; self.y = y }
    }
    public let textView = UITextView(usingTextLayoutManager: true)
    public var onPosition: (@MainActor (ReadingPosition, Bool) -> Void)?
    public var onFailure: (@MainActor (any Error) -> Void)?
    private var window: ReadingWindow?
    private var preferences = ReaderPreferences.defaults
    private var navigationID: UUID?
    private var applying = false
    private var lastSize: CGSize = .zero
    private var lastVisible: VisiblePosition?
    private var pending: (ReadingWindow, ReaderPreferences, ReadingPosition, UUID)?
    private var inputViewCoordinates: UIView {
        let input: any UITextInput = textView
        return input.textInputView ?? textView
    }

    public override func loadView() {
        view = UIView(); view.backgroundColor = .systemBackground
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.delegate = self; textView.isEditable = false; textView.isSelectable = true
        textView.alwaysBounceVertical = true
        textView.accessibilityIdentifier = "reader.text"
        textView.textContainerInset = .init(top: 24, left: 20, bottom: 40, right: 20)
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
        ])
    }

    public func update(window next: ReadingWindow, preferences nextPreferences: ReaderPreferences,
                       position: ReadingPosition, navigationID id: UUID) throws {
        loadViewIfNeeded()
        // Capture the semantic position before the width-change layout pass can
        // replace it with a fresh hit-test at the new geometry.
        let priorVisible = lastVisible
        view.layoutIfNeeded()
        if textView.bounds.width <= 0 || textView.bounds.height <= 0 {
            pending = (next, nextPreferences, position, id); return
        }
        if navigationID == id, textView.isDragging || textView.isDecelerating {
            pending = (next, nextPreferences, position, id); return
        }
        guard navigationID != id || window?.chapters != next.chapters || preferences != nextPreferences else { return }
        pending = nil
        let preserving: VisiblePosition?
        if navigationID == id, window != nil {
            // Keep the known semantic anchor across reflow. Re-hit-testing the
            // top edge after a width change can select a different character and
            // make the next font change drift by a line or a chapter.
            let candidate = priorVisible ?? (try capture())
            if (try? next.offset(of: candidate.anchor)) != nil {
                preserving = candidate
            } else {
                // A window change may evict the previous chapter; only then use
                // the caller's position, which belongs to the requested window.
                preserving = VisiblePosition(anchor: position, y: 24)
            }
        } else { preserving = VisiblePosition(anchor: position, y: 24) }
        if let preserving { _ = try next.offset(of: preserving.anchor) }
        // Selection is also semantic, independently of the visible reading point.
        let selection: (ReadingPosition, ReadingPosition)?
        if navigationID == id, let old = window, textView.selectedRange.length > 0 {
            selection = try (old.position(near: textView.selectedRange.location), old.position(near: NSMaxRange(textView.selectedRange)))
        } else { selection = nil }
        applying = true
        defer { applying = false }
        window = next; preferences = nextPreferences; navigationID = id
        overrideUserInterfaceStyle = nextPreferences.theme == .system ? .unspecified : (nextPreferences.theme == .dark ? .dark : .light)
        textView.backgroundColor = .systemBackground
        let styled = attributed(next, preferences: nextPreferences)
        textView.attributedText = styled
        view.layoutIfNeeded()
        guard let manager = textView.textLayoutManager, let content = manager.textContentManager else { throw Failure.unavailableLayout }
        manager.ensureLayout(for: content.documentRange)
        textView.selectedRange = NSRange(location: 0, length: 0)
        if let selection {
            // Eviction may remove a selection's other chapter. Collapse only that
            // selection; never substitute a different persisted reading anchor.
            if let start = try? next.offset(of: selection.0), let end = try? next.offset(of: selection.1), end >= start {
                textView.selectedRange = NSRange(location: start, length: end - start)
            }
        }
        if let preserving { try restore(preserving) }
        lastSize = textView.bounds.size
        lastVisible = try capture()
        if let lastVisible { onPosition?(lastVisible.anchor, false) }
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !applying, textView.bounds.width > 0 else { return }
        if window == nil, let pending {
            self.pending = nil
            do { try update(window: pending.0, preferences: pending.1, position: pending.2, navigationID: pending.3) }
            catch { onFailure?(error) }
            return
        }
        guard window != nil else { return }
        if lastSize != .zero, lastSize != textView.bounds.size, let lastVisible {
            applying = true
            defer { applying = false }
            do { try restore(lastVisible) } catch { onFailure?(error) }
        }
        lastSize = textView.bounds.size
    }

    public func capture() throws -> VisiblePosition {
        guard let window else { throw Failure.unavailablePosition }
        let point = CGPoint(x: textView.bounds.minX + textView.textContainerInset.left + textView.textContainer.lineFragmentPadding + 1,
            y: textView.bounds.minY + textView.adjustedContentInset.top + 1)
        guard let hit = textView.closestPosition(to: inputViewCoordinates.convert(point, from: textView)) else { throw Failure.unavailablePosition }
        let anchor = try window.position(near: textView.offset(from: textView.beginningOfDocument, to: hit))
        return try .init(anchor: anchor, y: visibleY(of: anchor))
    }

    public func visibleY(of anchor: ReadingPosition) throws -> CGFloat {
        guard let window, let location = textView.position(from: textView.beginningOfDocument, offset: try window.offset(of: anchor)) else {
            throw Failure.unavailablePosition
        }
        return view.convert(textView.caretRect(for: location), from: inputViewCoordinates).minY - textView.frame.minY
    }

    public func restore(_ position: VisiblePosition) throws {
        // Programmatic offsets and layout refinement also invoke scroll delegates.
        // Do not replace the saved pre-resize position with an intermediate hit.
        let wasApplying = applying
        applying = true
        defer { applying = wasApplying }
        // TextKit may refine paragraph geometry after scrolling. Re-measure
        // within a finite layout pass, preserving the experiment's 1pt contract.
        for pass in 1...3 {
            view.layoutIfNeeded(); textView.layoutIfNeeded()
            guard let layout = textView.textLayoutManager, let content = layout.textContentManager else { throw Failure.unavailableLayout }
            layout.ensureLayout(for: content.documentRange)
            let delta = try visibleY(of: position.anchor) - position.y
            let minimum = -textView.adjustedContentInset.top
            let maximum = max(minimum, textView.contentSize.height - textView.bounds.height + textView.adjustedContentInset.bottom)
            let proposed = textView.contentOffset.y + delta
            let clamped = min(maximum, max(minimum, proposed))
            textView.setContentOffset(CGPoint(x: 0, y: clamped), animated: false)
            textView.layoutIfNeeded()
            let observed = try visibleY(of: position.anchor)
            #if DEBUG
            print("ReadingRestoration pass=\(pass) expectedY=\(position.y) observedY=\(observed) requestedOffset=\(proposed) actualOffset=\(textView.contentOffset.y) contentHeight=\(textView.contentSize.height) width=\(textView.bounds.width)")
            #endif
            if abs(observed - position.y) <= 1 {
                lastVisible = try capture()
                return
            }
            // Only accept an actual document edge after all geometry refinements.
            // A pre-scroll estimated contentSize is not evidence of an edge.
            if pass == 3 {
                let finalMinimum = -textView.adjustedContentInset.top
                let finalMaximum = max(finalMinimum, textView.contentSize.height - textView.bounds.height + textView.adjustedContentInset.bottom)
                let actual = textView.contentOffset.y
                let atStart = abs(actual - finalMinimum) <= 1 && observed < position.y
                let atEnd = abs(actual - finalMaximum) <= 1 && observed > position.y
                if atStart || atEnd { lastVisible = try capture(); return }
            }
        }
        throw Failure.unsettledPosition
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !applying, window != nil, textView.bounds.size == lastSize,
              scrollView.isDragging || scrollView.isDecelerating || scrollView.isTracking else { return }
        do { lastVisible = try capture() } catch { onFailure?(error) }
    }
    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settled() }
    }
    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settled() }
    public func flushPosition() { settled(userScrolled: false) }

    private func settled(userScrolled: Bool = true) {
        guard !applying, window != nil else { return }
        do {
            let current = try capture(); lastVisible = current
            if let pending {
                self.pending = nil
                try update(window: pending.0, preferences: pending.1, position: current.anchor, navigationID: pending.3)
            }
            let displayed = try capture(); lastVisible = displayed
            onPosition?(displayed.anchor, userScrolled)
        } catch { onFailure?(error) }
    }

    private func attributed(_ window: ReadingWindow, preferences: ReaderPreferences) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6; paragraph.paragraphSpacing = 14
        let font = UIFont.systemFont(ofSize: preferences.fontSize)
        let text = NSMutableAttributedString(string: window.text, attributes: [.font: font, .foregroundColor: UIColor.label, .paragraphStyle: paragraph])
        for segment in window.segments {
            text.addAttribute(.font, value: UIFont.systemFont(ofSize: preferences.fontSize + 4, weight: .semibold), range: segment.titleRange)
            for block in segment.chapter.document.content.blocks {
                guard let value = block.paragraph, let range = segment.projection.paragraphs.first(where: { $0.id.utf8.elementsEqual(value.id.utf8) }) else { continue }
                var offset = segment.textRange.location + range.range.location
                let heading: Bool = { if case .heading = block { return true }; return false }()
                for run in value.runs {
                    guard case .text(let value, let style) = run else { continue }
                    var traits: UIFontDescriptor.SymbolicTraits = []
                    if style.strong || heading { traits.insert(.traitBold) }
                    if style.emphasis { traits.insert(.traitItalic) }
                    if !traits.isEmpty, let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
                        text.addAttribute(.font, value: UIFont(descriptor: descriptor, size: font.pointSize), range: NSRange(location: offset, length: value.utf16.count))
                    }
                    offset += value.utf16.count
                }
            }
        }
        return text
    }
}
#endif
