import Foundation
import LLMkit
import Network
import Testing

@testable import VoiceInk

/// An unavailable cleanup server (Cotabby with no model loaded answers 503) must not hold a
/// dictation for 12 s. Enhancement requests leave retries to LLMkit's chat clients, which try
/// three times; a timeout is retried only when the "retry on timeout" setting is on.
struct EnhancementRetryPolicyTests {
    @Test func anUnavailableServerGetsThreeRequests() async throws {
        let server = try FixtureServer(reply: .unavailable)
        let port = await server.start()
        defer { server.stop() }

        let error = await thrownError {
            try await chatCompletion(port: port, timeout: 7, retryOnTimeout: true)
        }

        if case .httpError(503, _) = error as? LLMKitError {} else { Issue.record("expected a 503, got \(String(describing: error))") }
        #expect(server.requests == 3)
    }

    @Test(arguments: [(true, 3), (false, 1)])
    func timeoutsFollowTheRetrySetting(retryOnTimeout: Bool, expectedRequests: Int) async throws {
        let server = try FixtureServer(reply: .never)
        let port = await server.start()
        defer { server.stop() }

        let error = await thrownError {
            try await chatCompletion(port: port, timeout: 0.3, retryOnTimeout: retryOnTimeout)
        }

        if case .timeout = error as? LLMKitError {} else { Issue.record("expected a timeout, got \(String(describing: error))") }
        #expect(server.requests == expectedRequests)
    }
}

/// The request `AIService.performChatCompletion` sends for a custom provider such as Cotabby.
private func chatCompletion(port: UInt16, timeout: TimeInterval, retryOnTimeout: Bool) async throws -> String {
    try await OpenAILLMClient.chatCompletion(
        baseURL: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!,
        apiKey: "fixture-key", model: "fixture", messages: [.user("raw words")],
        timeout: timeout, retryOnTimeout: retryOnTimeout
    )
}

private func thrownError(_ body: () async throws -> String) async -> (any Error)? {
    do {
        _ = try await body()
        return nil
    } catch {
        return error
    }
}

/// Loopback listener that answers every request with Cotabby's "model not available" 503, or
/// never answers.
private final class FixtureServer: @unchecked Sendable {
    enum Reply { case unavailable, never }

    private let listener: NWListener
    private let lock = NSLock()
    private var count = 0

    var requests: Int { lock.withLock { count } }

    init(reply: Reply) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                self.lock.withLock { self.count += 1 }
                guard reply == .unavailable else { return }
                let body = #"{"error":{"message":"The local model is not available","type":"unavailable"}}"#
                let response = "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\n"
                    + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    func start() async -> UInt16 {
        await withCheckedContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                if case .ready = state { continuation.resume(returning: listener.port!.rawValue) }
            }
            listener.start(queue: .global())
        }
    }

    func stop() { listener.cancel() }
}
