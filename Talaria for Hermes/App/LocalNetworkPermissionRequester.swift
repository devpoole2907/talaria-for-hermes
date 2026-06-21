import Foundation
@preconcurrency import Network

@MainActor
enum LocalNetworkPermissionRequester {
    static func request() async {
        await withCheckedContinuation { continuation in
            LocalNetworkPermissionProbe(continuation: continuation).start()
        }
    }
}

@MainActor
private final class LocalNetworkPermissionProbe {
    private let browser: NWBrowser
    private let continuation: CheckedContinuation<Void, Never>
    private var timeoutTask: Task<Void, Never>?
    private var didFinish = false

    init(continuation: CheckedContinuation<Void, Never>) {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        self.browser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: parameters)
        self.continuation = continuation
    }

    func start() {
        browser.stateUpdateHandler = { [self] state in
            let finishDelay: Duration?
            switch state {
            case .ready, .failed, .cancelled:
                finishDelay = .zero
            case .waiting:
                finishDelay = .seconds(1)
            case .setup:
                finishDelay = nil
            @unknown default:
                finishDelay = .zero
            }

            if let finishDelay {
                Task { @MainActor [self] in
                    if finishDelay > .zero {
                        try? await Task.sleep(for: finishDelay)
                    }
                    finish()
                }
            }
        }

        browser.browseResultsChangedHandler = { [self] _, _ in
            Task { @MainActor [self] in
                finish()
            }
        }

        browser.start(queue: .main)

        timeoutTask = Task { @MainActor [self] in
            try? await Task.sleep(for: .seconds(3))
            finish()
        }
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        timeoutTask?.cancel()
        timeoutTask = nil
        browser.stateUpdateHandler = nil
        browser.browseResultsChangedHandler = nil
        browser.cancel()
        continuation.resume()
    }
}
