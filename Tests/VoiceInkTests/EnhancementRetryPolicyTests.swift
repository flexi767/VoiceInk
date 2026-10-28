import Foundation
import LLMkit
import Network
import Testing

@testable import VoiceInk

/// An unavailable cleanup server (Cotabby with no model loaded answers 503) must not hold a
/// dictation for 12 s. LLMkit's chat clients already retry 5xx, 429 and connection failures for
/// most providers, so the enhancement retry loop must not repeat them on top; OpenRouter's client
/// opts out of LLMkit retries and keeps the loop's.
struct EnhancementRetryPolicyTests {
    @Test func customProviderMakesOneLLMkitCallToAnUnavailableServer() async throws {
        let server = try UnavailableServer()
        let port = await server.start()
        defer { server.stop() }
        let loop = EnhancementRetryLoop(provider: .custom, retryOnTimeout: true, initialDelay: 0.01)

        let error = await thrownError {
            try await loop.run {
                do {
                    return try await OpenAILLMClient.chatCompletion(
                        baseURL: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!,
                        apiKey: "fixture-key", model: "fixture", messages: [.user("raw words")], timeout: 7
                    )
                } catch let error as LLMKitError {
                    throw EnhancementError(error)
                }
            }
        }

        #expect(isServerError(error))
        #expect(server.requests == 3)
    }

    @Test(arguments: [AIProvider.openRouter, .ollama, .localCLI, .voiceInkRefine])
    func providersWithoutAnInnerRetryKeepTheLoopsRetries(provider: AIProvider) async {
        var attempts = 0
        let loop = EnhancementRetryLoop(provider: provider, retryOnTimeout: true, initialDelay: 0.01)

        let error = await thrownError {
            try await loop.run { () async throws -> String in
                attempts += 1
                throw EnhancementError(LLMKitError.httpError(statusCode: 503, message: "unavailable"))
            }
        }

        #expect(isServerError(error))
        #expect(attempts == 3)
    }

    @Test(arguments: [(AIProvider.custom, true, 3), (.custom, false, 1), (.localCLI, true, 3), (.localCLI, false, 1)])
    func timeoutsFollowTheRetrySetting(provider: AIProvider, retryOnTimeout: Bool, expectedAttempts: Int) async {
        var attempts = 0
        let loop = EnhancementRetryLoop(provider: provider, retryOnTimeout: retryOnTimeout, initialDelay: 0.01)

        let error = await thrownError {
            try await loop.run { () async throws -> String in
                attempts += 1
                throw EnhancementError.timeout
            }
        }

        if case .timeout = error as? EnhancementError {} else { Issue.record("expected a timeout, got \(String(describing: error))") }
        #expect(attempts == expectedAttempts)
    }
}

private func thrownError(_ body: () async throws -> String) async -> (any Error)? {
    do {
        _ = try await body()
        return nil
    } catch {
        return error
    }
}

/// The pipeline formats and notifies this error, then pastes the raw transcript.
private func isServerError(_ error: (any Error)?) -> Bool {
    if case .serverError = error as? EnhancementError { return true }
    return false
}

/// Loopback listener that answers every request with Cotabby's "model not available" 503.
private final class UnavailableServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var count = 0

    var requests: Int { lock.withLock { count } }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                self.lock.withLock { self.count += 1 }
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
