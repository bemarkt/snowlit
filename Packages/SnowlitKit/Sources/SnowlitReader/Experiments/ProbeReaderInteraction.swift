#if os(iOS) && DEBUG
import SnowlitCore
import UIKit

/// An explicit Debug launch destination for system gesture observations, never a product reader.
@_spi(Experiments)
@MainActor
public func makeReaderInteractionProbe() -> UIViewController {
    ProbeReaderInteraction()
}

@MainActor
private final class ProbeReaderInteraction: UIViewController {
    private let status = UILabel()
    private var curl: ProbePageCurl?
    private var renderedSize: CGSize?
    private var layoutFailed = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        status.numberOfLines = 0
        status.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        status.accessibilityIdentifier = "probe.reader-status"
        status.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(status)
        NSLayoutConstraint.activate([
            status.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            status.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            status.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            status.heightAnchor.constraint(equalToConstant: 64),
        ])
        do {
            let pages = try (1...2).map { number in
                let document = try ProbeDocument(id: "gesture-page-\(number)", paragraphs: [
                    ProbeParagraph(id: "heading", runs: [.text("第 \(number) 页")]),
                    ProbeParagraph(id: "body", runs: [.text("这是一段用于系统卷页实验的文字。\n中文、English、👩🏽‍💻 与 e\u{301} 保留在原生文本视口中。")]),
                ])
                let page = ProbeViewport(document: document)
                page.loadViewIfNeeded()
                // Prepared page snapshots do not compete with the curl's pan gesture.
                // Continuous scrolling and selection have their own viewport experiments.
                page.textView.isScrollEnabled = false
                page.textView.isSelectable = false
                return page
            }
            let curl = ProbePageCurl(first: pages[0], second: pages[1])
            self.curl = curl
            curl.onTransitionChange = { [weak self] in self?.refreshStatus() }
            addChild(curl.controller)
            curl.controller.view.translatesAutoresizingMaskIntoConstraints = false
            curl.controller.view.accessibilityIdentifier = "probe.curl-surface"
            view.addSubview(curl.controller.view)
            NSLayoutConstraint.activate([
                curl.controller.view.topAnchor.constraint(equalTo: status.bottomAnchor),
                curl.controller.view.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
                curl.controller.view.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
                curl.controller.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            ])
            curl.controller.didMove(toParent: self)
            refreshStatus()
        } catch {
            layoutFailed = true
            status.text = "failed=initialization"
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let curl, !layoutFailed, !curl.transitionInProgress else { return }
        let size = curl.controller.view.bounds.size
        guard size.width > 0, size.height > 0, size != renderedSize else { return }
        renderedSize = size
        do {
            for page in curl.pages {
                page.view.frame = CGRect(origin: .zero, size: size)
                try page.render(fontSize: 22)
            }
            refreshStatus()
        } catch {
            layoutFailed = true
            status.text = "failed=layout"
        }
    }

    private func refreshStatus() {
        guard let curl, !layoutFailed else { return }
        let visible = (curl.controller.viewControllers?.first as? ProbeViewport)?.projection.document.id ?? "none"
        status.text = "page=\(curl.committedPage);visible=\(visible);began=\(curl.interactiveTransitions);completed=\(curl.completedTransitions);cancelled=\(curl.cancelledTransitions);active=\(curl.transitionInProgress);laidOut=\(renderedSize != nil)"
        if !curl.transitionInProgress { view.setNeedsLayout() }
    }
}
#endif
