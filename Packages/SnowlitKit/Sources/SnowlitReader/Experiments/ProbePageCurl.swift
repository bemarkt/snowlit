#if os(iOS)
import UIKit

/// Two prepared viewport pages only. Does not implement page breaking or the final reader.
@MainActor
final class ProbePageCurl: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    let controller = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal,
        options: [.spineLocation: UIPageViewController.SpineLocation.min.rawValue])
    let pages: [ProbeViewport]
    private(set) var committedPage = 0
    private(set) var transitionInProgress = false
    private(set) var interactiveTransitions = 0
    private(set) var completedTransitions = 0
    private(set) var cancelledTransitions = 0
    var onTransitionChange: (() -> Void)?

    init(first: ProbeViewport, second: ProbeViewport) {
        pages = [first, second]
        super.init()
        controller.dataSource = self
        controller.delegate = self
        controller.isDoubleSided = false
        controller.setViewControllers([first], direction: .forward, animated: false)
    }

    @discardableResult
    func show(_ index: Int, animated: Bool) async -> Bool {
        guard pages.indices.contains(index), !transitionInProgress else { return false }
        transitionInProgress = true
        let direction: UIPageViewController.NavigationDirection = index >= committedPage ? .forward : .reverse
        return await withCheckedContinuation { continuation in
            controller.setViewControllers([pages[index]], direction: direction, animated: animated) { [weak self] finished in
                guard let self else { continuation.resume(returning: false); return }
                if finished { committedPage = index }
                transitionInProgress = false
                continuation.resume(returning: finished)
            }
        }
    }

    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let index = pages.firstIndex(where: { $0 === viewController }), index > 0 else { return nil }
        return pages[index - 1]
    }

    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let index = pages.firstIndex(where: { $0 === viewController }), index + 1 < pages.count else { return nil }
        return pages[index + 1]
    }

    func pageViewController(_ pageViewController: UIPageViewController,
                            willTransitionTo pendingViewControllers: [UIViewController]) {
        transitionInProgress = true
        interactiveTransitions += 1
        onTransitionChange?()
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        defer {
            transitionInProgress = false
            onTransitionChange?()
        }
        guard completed else { cancelledTransitions += 1; return }
        guard let visible = pageViewController.viewControllers?.first,
              let index = pages.firstIndex(where: { $0 === visible }) else { return }
        committedPage = index
        completedTransitions += 1
    }
}
#endif
