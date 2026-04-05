//
//  SpotifyAPI.swift
//  Spotifly
//
//  Spotify Web API client - base definitions and utilities.
//

import Foundation

/// Spotify item types for generating external URLs
enum SpotifyItemType: String {
    case track
    case album
    case artist
    case playlist
    case user
}

/// Generates a Spotify external URL from item type and ID
func spotifyExternalUrl(type: SpotifyItemType, id: String) -> String {
    "https://open.spotify.com/\(type.rawValue)/\(id)"
}

// MARK: - Rate Limiter

/// Token bucket rate limiter — caps outgoing Spotify API requests to avoid 429s.
/// Max 5 requests/second with a burst capacity of 5.
private actor RateLimiter {
    private let maxTokens: Double = 5
    private let refillRate: Double = 5 // tokens per second
    private var tokens: Double = 5
    private var lastRefill: Date = Date()

    func wait() async throws {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRefill)
        tokens = min(maxTokens, tokens + elapsed * refillRate)
        lastRefill = now

        if tokens >= 1 {
            tokens -= 1
            return
        }

        // Sleep until we have a token
        let delay = (1.0 - tokens) / refillRate
        tokens = 0
        lastRefill = Date()
        try await Task.sleep(for: .seconds(delay))
    }
}

private let rateLimiter = RateLimiter()

// MARK: - Spotify API

/// Spotify Web API client
enum SpotifyAPI {
    static let baseURL = "https://api.spotify.com/v1"

    /// Performs a URL request with automatic retry on 429 (rate limit).
    ///
    /// When Spotify returns 429, reads the `Retry-After` header and waits that many seconds
    /// before retrying. Falls back to exponential backoff if the header is missing.
    /// After maxRetries exhausted, returns the final 429 response for the caller to handle.
    static func data(for request: URLRequest, maxRetries: Int = 3) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            try await rateLimiter.wait()
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SpotifyAPIError.invalidResponse
            }

            guard httpResponse.statusCode == 429 else {
                return (data, httpResponse)
            }

            attempt += 1
            if attempt > maxRetries {
                debugLog("SpotifyAPI", "[RATE LIMITED] Max retries (\(maxRetries)) exceeded for \(request.url?.path ?? "?")")
                return (data, httpResponse)
            }

            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                .flatMap(Double.init) ?? Double(attempt * 2)
            debugLog("SpotifyAPI", "[RATE LIMITED] 429 received — Retry-After: \(retryAfter)s (attempt \(attempt)/\(maxRetries)) for \(request.url?.path ?? "?")")

            // If Spotify wants us to wait more than 30s, the rate limit window is too large
            // to retry transparently — fail immediately so the UI stays responsive.
            guard retryAfter <= 30 else {
                debugLog("SpotifyAPI", "[RATE LIMITED] Retry-After \(retryAfter)s exceeds 30s cap — failing immediately")
                return (data, httpResponse)
            }
            try await Task.sleep(for: .seconds(retryAfter))
        }
    }

    /// Helper to throw appropriate error from API error response data
    static func throwAPIError(data: Data, statusCode: Int) throws -> Never {
        let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
        debugLog("SpotifyAPI", "[HTTP \(statusCode)] \(body)")
        if let errorResponse = try? JSONDecoder().decode(SpotifyErrorResponse.self, from: data) {
            throw SpotifyAPIError.apiError(errorResponse.error.message)
        }
        throw SpotifyAPIError.apiError("HTTP \(statusCode)")
    }

    /// Parses a Spotify URI (spotify:track:xxx) and returns the track ID
    static func parseTrackURI(_ uri: String) -> String? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)

        // Handle spotify:track:ID format
        if trimmed.hasPrefix("spotify:track:") {
            return String(trimmed.dropFirst("spotify:track:".count))
        }

        // Handle open.spotify.com/track/ID format
        if trimmed.contains("open.spotify.com/track/") {
            if let range = trimmed.range(of: "open.spotify.com/track/") {
                var trackId = String(trimmed[range.upperBound...])
                // Remove query parameters if present
                if let queryIndex = trackId.firstIndex(of: "?") {
                    trackId = String(trackId[..<queryIndex])
                }
                return trackId.isEmpty ? nil : trackId
            }
        }

        return nil
    }
}
