//
//  StoreCache.swift
//  Spotifly
//
//  Persists AppStore entity data to disk so subsequent app launches skip API calls.
//  Uses a per-section TTL: library lists (albums/artists/playlists) expire after 24h,
//  favorites expire after 1h. Stale sections are silently dropped and re-fetched.
//

import Foundation

// MARK: - Cache File Location

private let cacheFileName = "spotifly_store_cache.json"

private var cacheFileURL: URL? {
    FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first?
        .appendingPathComponent("Spotifly", isDirectory: true)
        .appendingPathComponent(cacheFileName)
}

// MARK: - Cache Envelope

/// Wraps a cached value with its save timestamp for TTL checks.
struct CacheSection<T: Codable>: Codable {
    let data: T
    let savedAt: Date

    func isExpired(ttl: TimeInterval) -> Bool {
        Date().timeIntervalSince(savedAt) > ttl
    }
}

// MARK: - Cache Snapshot

/// Full serializable snapshot of cacheable AppStore state.
struct CacheSnapshot: Codable {
    // Entity tables
    var tracks: CacheSection<[String: Track]>?
    var albums: CacheSection<[String: Album]>?
    var artists: CacheSection<[String: Artist]>?
    var playlists: CacheSection<[String: Playlist]>?

    // User library ID lists
    var userAlbumIds: CacheSection<[String]>?
    var userArtistIds: CacheSection<[String]>?
    var userPlaylistIds: CacheSection<[String]>?
    var savedTrackIds: CacheSection<[String]>?
    var favoriteTrackIds: CacheSection<[String]>? // Set<String> stored as [String]

    // Pagination state (saved alongside their data)
    var albumsPagination: CacheSection<PaginationState>?
    var artistsPagination: CacheSection<PaginationState>?
    var playlistsPagination: CacheSection<PaginationState>?
    var favoritesPagination: CacheSection<PaginationState>?
}

// MARK: - StoreCache

enum StoreCache {
    // MARK: - Save

    /// Serializes the current AppStore state to disk. Call after major data loads.
    @MainActor
    static func save(from store: AppStore) {
        let now = Date()

        let snapshot = CacheSnapshot(
            tracks: CacheSection(data: store.cachedTracks, savedAt: now),
            albums: CacheSection(data: store.cachedAlbums, savedAt: now),
            artists: CacheSection(data: store.cachedArtists, savedAt: now),
            playlists: CacheSection(data: store.cachedPlaylists, savedAt: now),
            userAlbumIds: CacheSection(data: store.cachedUserAlbumIds, savedAt: now),
            userArtistIds: CacheSection(data: store.cachedUserArtistIds, savedAt: now),
            userPlaylistIds: CacheSection(data: store.cachedUserPlaylistIds, savedAt: now),
            savedTrackIds: CacheSection(data: store.cachedSavedTrackIds, savedAt: now),
            favoriteTrackIds: CacheSection(data: Array(store.cachedFavoriteTrackIds), savedAt: now),
            albumsPagination: CacheSection(data: store.albumsPagination, savedAt: now),
            artistsPagination: CacheSection(data: store.artistsPagination, savedAt: now),
            playlistsPagination: CacheSection(data: store.playlistsPagination, savedAt: now),
            favoritesPagination: CacheSection(data: store.favoritesPagination, savedAt: now),
        )

        guard let url = cacheFileURL else { return }

        do {
            // Ensure Spotifly/ directory exists
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
            debugLog("StoreCache", "Saved cache (\(data.count / 1024)KB) to \(url.lastPathComponent)")
        } catch {
            debugLog("StoreCache", "Save failed: \(error)")
        }
    }

    // MARK: - Load

    /// Loads the cache from disk. Returns nil if missing, corrupt, or fully expired.
    /// Individual sections may still be nil/expired — callers should check each section.
    static func load() -> CacheSnapshot? {
        guard let url = cacheFileURL,
              let data = try? Data(contentsOf: url) else {
            debugLog("StoreCache", "No cache file found")
            return nil
        }

        do {
            let snapshot = try JSONDecoder().decode(CacheSnapshot.self, from: data)
            debugLog("StoreCache", "Loaded cache from disk (\(data.count / 1024)KB)")
            return snapshot
        } catch {
            debugLog("StoreCache", "Cache decode failed (will re-fetch): \(error)")
            // Delete corrupt cache
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    // MARK: - Clear

    static func clear() {
        guard let url = cacheFileURL else { return }
        try? FileManager.default.removeItem(at: url)
        debugLog("StoreCache", "Cache cleared")
    }
}
