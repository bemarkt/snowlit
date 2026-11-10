#if os(iOS) && DEBUG
import Foundation
import UIKit
import SwiftUI
@_spi(Experiments) import YingxueKit

struct RuntimeLifecycleProbeView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { RuntimeLifecycleProbe() }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

/// Debug-only UI fixture for actual Home/activate lifecycle transitions. It owns
/// its finite tasks and WebViews; no library or website credentials are involved.
@MainActor
private final class RuntimeLifecycleProbe: UIViewController {
    private let status = UILabel()
    private let start = UIButton(type: .system)
    private var runtime: RuntimeLifecycleSession?
    private var work: Task<Void, Never>?
    private var generation = UUID()
    private var ready = 0
    private var entered = 0
    private var background = 0
    private var discarded = 0
    private var writes = 0
    private var failures = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        status.accessibilityIdentifier = "probe.runtime-status"
        status.numberOfLines = 0
        start.setTitle("Start pending operation", for: .normal)
        start.accessibilityIdentifier = "probe.runtime-start"
        start.addTarget(self, action: #selector(beginPending), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [status, start])
        stack.axis = .vertical; stack.spacing = 20; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            start.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(didBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didActivate), name: UIApplication.didBecomeActiveNotification, object: nil)
        render()
    }

    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); didActivate() }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        retire()
    }

    @objc private func didActivate() {
        guard runtime == nil, isViewLoaded, view.window != nil else { return }
        let current = generation
        let probe = RuntimeLifecycleSession()
        runtime = probe
        work = Task { [weak self] in
            do {
                try await probe.prepare()
                guard let self, generation == current else { return }
                ready += 1; render()
            } catch {
                guard let self, generation == current else { return }
                failures += 1; render()
            }
        }
    }

    @objc private func beginPending() {
        guard let runtime, start.isEnabled else { return }
        start.isEnabled = false
        let current = generation
        work = Task { [weak self] in
            do {
                try await runtime.waitForInterruption { [weak self] in
                    guard let self, generation == current else { return }
                    entered += 1; render()
                }
                guard let self else { return }
                if generation == current { writes += 1 } else { discarded += 1 }
                render()
            } catch {
                guard let self else { return }
                if generation == current { failures += 1 } else { discarded += 1 }
                render()
            }
        }
    }

    @objc private func didBackground() { background += 1; retire(); render() }

    private func retire() {
        generation = UUID()
        runtime?.close()
        runtime = nil
        work?.cancel(); work = nil
    }

    private func render() {
        status.text = "ready=\(ready);entered=\(entered);background=\(background);discarded=\(discarded);writes=\(writes);failures=\(failures);"
        start.isEnabled = runtime != nil && ready > entered
    }
}
#endif
