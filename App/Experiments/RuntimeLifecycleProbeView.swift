#if os(iOS) && DEBUG
import Foundation
import UIKit
import SwiftUI
import WebKit
@_spi(Experiments) import YingxueKit

struct RuntimeLifecycleProbeView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { RuntimeLifecycleProbe() }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

/// Debug-only UI fixture for actual Home/activate lifecycle transitions. It owns
/// its finite tasks and WebViews; no library or website credentials are involved.
@MainActor
private final class RuntimeLifecycleProbe: UIViewController {
    private enum Phase: String { case inactive, preparing, ready, pending, failed }
    private let status = UILabel()
    private let start = UIButton(type: .system)
    // Foreground rebuilds replace execution, not the source's website session.
    // Keep this one fixture's store alive to test whether repeated store/process
    // creation caused the third foreground preparation timeout.
    private let websiteDataStore = WKWebsiteDataStore.nonPersistent()
    private var runtime: RuntimeLifecycleSession?
    private var work: Task<Void, Never>?
    private var generation = UUID()
    private var ready = 0
    private var entered = 0
    private var background = 0
    private var discarded = 0
    private var writes = 0
    private var failures = 0
    private var phase = Phase.inactive
    private var lastFailure = "none"

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
        guard UIApplication.shared.applicationState == .active,
              runtime == nil, isViewLoaded, view.window != nil else { return }
        let current = generation
        let probe = RuntimeLifecycleSession(dataStore: websiteDataStore)
        runtime = probe
        phase = .preparing
        render()
        work = Task { [weak self] in
            do {
                try await probe.prepare()
                guard let self, generation == current else { return }
                ready += 1; phase = .ready; render()
            } catch {
                guard let self, generation == current else { return }
                recordFailure(error, operation: "prepare")
            }
        }
    }

    @objc private func beginPending() {
        guard let runtime, phase == .ready else { return }
        phase = .pending
        render()
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
                if generation == current { recordFailure(error, operation: "pending") } else { discarded += 1 }
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
        phase = .inactive
    }

    private func recordFailure(_ error: any Error, operation: String) {
        failures += 1
        phase = .failed
        let native = error as NSError
        // Keep failure category available to UI assertions without website data.
        lastFailure = "\(operation):\(native.domain):\(native.code)"
        render()
    }

    private func render() {
        status.text = "ready=\(ready);entered=\(entered);background=\(background);discarded=\(discarded);writes=\(writes);failures=\(failures);phase=\(phase.rawValue);lastFailure=\(lastFailure);"
        start.isEnabled = phase == .ready
    }
}
#endif
