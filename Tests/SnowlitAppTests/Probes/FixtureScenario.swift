#if os(iOS)
import Foundation
import Testing

@MainActor
final class FixtureScenario {
    enum Failure: Error { case invalidResponse, wrongFixture, deadline }

    let base: URL
    private let session: URLSession

    private init(base: URL, session: URLSession) {
        self.base = base
        self.session = session
    }

    /// A missing fixture fails the test. No environment-based skip can turn it green.
    static func withScenario(_ body: @MainActor (FixtureScenario) async throws -> Void) async throws {
        try #require(Bundle.main.bundleIdentifier == "io.github.bemarkt.snowlit")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let origin = URL(string: "http://127.0.0.1:18731")!
        var request = URLRequest(url: origin.appendingPathComponent("scenarios"))
        request.httpMethod = "POST"
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 201,
              let created = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let path = created["path"],
              let base = URL(string: path, relativeTo: origin)?.absoluteURL else {
            throw Failure.invalidResponse
        }
        guard created["fixtureVersion"] == "runtime-probe-1" else { throw Failure.wrongFixture }
        let scenario = FixtureScenario(base: base, session: session)
        do {
            try await body(scenario)
        } catch {
            do {
                let (_, observation) = try await scenario.request("status")
                // The synthetic status contains only route/method and request counts.
                // Never include cookies, request bodies or protected content here.
                print("FixtureFailureObservation \(String(decoding: observation, as: UTF8.self))")
            } catch { Issue.record(error, "Fixture failure observation unavailable") }
            do { _ = try await scenario.request("", method: "DELETE") }
            catch { Issue.record(error, "Fixture scenario cleanup failed") }
            throw error
        }
        let (status, _) = try await scenario.request("", method: "DELETE")
        #expect(status == 200)
    }

    func url(_ path: String) -> URL { base.appendingPathComponent(path) }

    func request(_ path: String, method: String = "GET") async throws -> (Int, Data) {
        var request = URLRequest(url: url(path))
        request.httpMethod = method
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        return (response.statusCode, data)
    }

    func status() async throws -> [String: Any] {
        let (code, data) = try await request("status")
        guard code == 200, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw Failure.invalidResponse }
        return value
    }

    static func eventually(_ check: @MainActor () async throws -> Bool) async throws {
        let clock = ContinuousClock()
        // Presentation can include one real WebKit page load (15-second budget);
        // keep the test wait aligned with that native budget instead of a 5s one.
        let deadline = clock.now.advanced(by: .seconds(15))
        while try await !check() {
            guard clock.now < deadline else { throw Failure.deadline }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
#endif
