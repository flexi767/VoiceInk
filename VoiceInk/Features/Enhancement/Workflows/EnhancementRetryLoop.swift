import Foundation
import LLMkit
import OSLog

/// Sends an enhancement request again after a retryable failure. `AIEnhancementService` runs every
/// request through it; it is separate so tests can drive the real loop against a synthetic server.
struct EnhancementRetryLoop {
    let provider: AIProvider?
    let retryOnTimeout: Bool
    let maxAttempts: Int
    let initialDelay: TimeInterval

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AIEnhancementService")

    init(
        provider: AIProvider?,
        retryOnTimeout: Bool,
        maxAttempts: Int = EnhancementRequestSettings.maximumAttempts,
        initialDelay: TimeInterval = 1.0
    ) {
        self.provider = provider
        self.retryOnTimeout = retryOnTimeout
        self.maxAttempts = maxAttempts
        self.initialDelay = initialDelay
    }

    func run<Result>(_ attempt: () async throws -> Result) async throws -> Result {
        var retries = 0
        var currentDelay = initialDelay

        while retries < maxAttempts {
            do {
                return try await attempt()
            } catch let error as EnhancementError {
                switch error {
                case .networkError, .serverError, .rateLimitExceeded:
                    if let provider, EnhancementRequestSettings.providersRetriedByLLMkit.contains(provider) {
                        throw error
                    }
                    retries += 1
                    if retries < maxAttempts {
                        logger.warning(
                            "Request failed, retrying in \(currentDelay, privacy: .public)s... (Attempt \(retries, privacy: .public)/\(maxAttempts, privacy: .public))"
                        )
                        try await Task.sleep(nanoseconds: UInt64(currentDelay * 1_000_000_000))
                        currentDelay *= 2
                    } else {
                        logger.error("Request failed after \(maxAttempts, privacy: .public) attempts.")
                        throw error
                    }
                case .timeout:
                    if retryOnTimeout {
                        retries += 1
                        if retries < maxAttempts {
                            logger.warning(
                                "Request timed out, retrying immediately... (Attempt \(retries, privacy: .public)/\(maxAttempts, privacy: .public))"
                            )
                        } else {
                            logger.error("Request timed out after \(maxAttempts, privacy: .public) attempts.")
                            throw error
                        }
                    } else {
                        logger.error("Request timed out, failing immediately (retry disabled).")
                        throw error
                    }
                default:
                    throw error
                }
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain
                    && [NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost].contains(
                        nsError.code)
                {
                    retries += 1
                    if retries < maxAttempts {
                        logger.warning(
                            "Request failed with network error, retrying in \(currentDelay, privacy: .public)s... (Attempt \(retries, privacy: .public)/\(maxAttempts, privacy: .public))"
                        )
                        try await Task.sleep(nanoseconds: UInt64(currentDelay * 1_000_000_000))
                        currentDelay *= 2
                    } else {
                        logger.error("Request failed after \(maxAttempts, privacy: .public) attempts with network error.")
                        throw EnhancementError.networkError
                    }
                } else {
                    throw error
                }
            }
        }

        throw EnhancementError.enhancementFailed
    }
}

extension EnhancementError {
    init(_ error: LLMKitError) {
        switch error {
        case .missingAPIKey:
            self = .notConfigured
        case .httpError(let statusCode, let message):
            if statusCode == 429 { self = .rateLimitExceeded; return }
            if statusCode == 408 { self = .timeout; return }
            if (500...599).contains(statusCode) { self = .serverError; return }
            self = .customError("HTTP \(statusCode): \(message)")
        case .noResultReturned:
            self = .enhancementFailed
        case .networkError:
            self = .networkError
        case .timeout:
            self = .timeout
        case .invalidURL, .decodingError, .encodingError:
            self = .customError(error.localizedDescription)
        case .unsupportedModel(let model):
            self = .customError("Unsupported model: \(model)")
        }
    }
}
