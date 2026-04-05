//
//  ArtistDetailView.swift
//  Spotifly
//
//  Shows details for an artist with top tracks, using normalized store
//

import SwiftUI

struct ArtistDetailView: View {
    /// ID is always required (either passed directly or derived from artist object)
    let artistId: String

    /// Optional pre-loaded artist (avoids network request if already have data)
    private let initialArtist: Artist?

    @Bindable var playbackViewModel: PlaybackViewModel
    @Environment(SpotifySession.self) private var session
    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    @Environment(AppStore.self) private var store
    @Environment(ArtistService.self) private var artistService
    @Environment(\.displayScale) private var displayScale

    @State private var artist: Artist?
    @State private var topTracks: [Track] = []

    // Albums section
    @State private var albums: [Album] = []
    @State private var albumsTotal: Int = 0
    @State private var albumsOffset: Int = 0
    @State private var albumsHasMore: Bool = false
    @State private var isLoadingMoreAlbums: Bool = false

    // Singles & EPs section
    @State private var singles: [Album] = []
    @State private var singlesTotal: Int = 0
    @State private var singlesOffset: Int = 0
    @State private var singlesHasMore: Bool = false
    @State private var isLoadingMoreSingles: Bool = false

    // Compilations section
    @State private var compilations: [Album] = []
    @State private var compilationsTotal: Int = 0
    @State private var compilationsOffset: Int = 0
    @State private var compilationsHasMore: Bool = false
    @State private var isLoadingMoreCompilations: Bool = false

    @State private var isLoadingArtist = false
    @State private var isLoadingReleases = false
    @State private var isLoadingTopTracks = false
    @State private var errorMessage: String?
    @State private var showUnfollowConfirmation = false

    /// Whether this artist is in the user's followed artists
    private var isFollowing: Bool {
        store.userArtistIds.contains(artistId)
    }

    /// Initialize with an artist ID (fetches artist data)
    init(artistId: String, playbackViewModel: PlaybackViewModel) {
        self.artistId = artistId
        initialArtist = nil
        self.playbackViewModel = playbackViewModel
    }

    /// Initialize with a pre-loaded artist (avoids network request)
    init(artist: Artist, playbackViewModel: PlaybackViewModel) {
        artistId = artist.id
        initialArtist = artist
        self.playbackViewModel = playbackViewModel
    }

    var body: some View {
        Group {
            if let artist {
                artistContent(artist)
            } else if isLoadingArtist {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                VStack {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                    Button("action.try_again") {
                        Task { await loadArtist() }
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(artist?.name ?? "")
        .task(id: artistId) {
            // Debounce: if user clicks through artists quickly, cancel before firing requests
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            // Reset state for new artist
            topTracks = []
            albums = []; albumsOffset = 0; albumsHasMore = false
            singles = []; singlesOffset = 0; singlesHasMore = false
            compilations = []; compilationsOffset = 0; compilationsHasMore = false
            // Use initial artist if provided, otherwise fetch
            if let initialArtist {
                artist = initialArtist
            } else {
                await loadArtist()
            }
            await loadTopTracks()
            await loadReleases()
        }
        .alert("artist.unfollow.title", isPresented: $showUnfollowConfirmation) {
            Button("action.cancel", role: .cancel) {}
            Button("artist.unfollow.action", role: .destructive) {
                unfollowArtist()
            }
        } message: {
            Text("artist.unfollow.message \(artist?.name ?? "")")
        }
        .onReceive(NotificationCenter.default.publisher(for: .showArtistUnfollowConfirmation)) { notification in
            if let notificationArtistId = notification.object as? String, notificationArtistId == artistId {
                showUnfollowConfirmation = true
            }
        }
    }

    private func artistContent(_ artist: Artist) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                // Artist image and metadata
                VStack(spacing: 16) {
                    if let url = artist.images.url(for: 200, scale: displayScale) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .empty:
                                ProgressView()
                                    .frame(width: 200, height: 200)
                            case let .success(image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 200, height: 200)
                                    .clipShape(Circle())
                                    .shadow(radius: 10)
                            case .failure:
                                Image(systemName: "person.circle.fill")
                                    .resizable()
                                    .frame(width: 200, height: 200)
                                    .foregroundStyle(.gray.opacity(0.3))
                            @unknown default:
                                EmptyView()
                            }
                        }
                    } else {
                        Image(systemName: "person.circle.fill")
                            .resizable()
                            .frame(width: 200, height: 200)
                            .foregroundStyle(.gray.opacity(0.3))
                    }

                    VStack(spacing: 8) {
                        Text(artist.name)
                            .font(.title)
                            .fontWeight(.bold)
                            .multilineTextAlignment(.center)

                        if !artist.genres.isEmpty {
                            Text(artist.genres.prefix(3).joined(separator: ", "))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
                .padding(.top, 24)

                // Top Tracks Section
                if isLoadingTopTracks {
                    ProgressView("loading.top_tracks")
                        .padding()
                } else if !topTracks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("section.top_tracks")
                            .font(.headline)
                            .padding(.horizontal)

                        ForEach(Array(topTracks.enumerated()), id: \.element.id) { index, track in
                            TrackRow(
                                track: track,
                                index: index + 1,
                                currentlyPlayingURI: playbackViewModel.currentTrackUri,
                                playbackViewModel: playbackViewModel,
                            )
                        }
                    }
                }

                // Albums / Singles+EPs / Compilations
                if isLoadingReleases {
                    ProgressView("loading.albums")
                        .padding()
                } else {
                    releaseSection(
                        title: "Albums",
                        items: albums,
                        total: albumsTotal,
                        hasMore: albumsHasMore,
                        isLoadingMore: isLoadingMoreAlbums,
                        loadMore: { Task { await loadMoreSection(group: "album") } }
                    )
                    releaseSection(
                        title: "Singles & EPs",
                        items: singles,
                        total: singlesTotal,
                        hasMore: singlesHasMore,
                        isLoadingMore: isLoadingMoreSingles,
                        loadMore: { Task { await loadMoreSection(group: "single") } }
                    )
                    releaseSection(
                        title: "Compilations",
                        items: compilations,
                        total: compilationsTotal,
                        hasMore: compilationsHasMore,
                        isLoadingMore: isLoadingMoreCompilations,
                        loadMore: { Task { await loadMoreSection(group: "compilation") } }
                    )
                }
            }
            .padding(.bottom, 100)
        }
    }

    @ViewBuilder
    private func releaseSection(
        title: String,
        items: [Album],
        total: Int,
        hasMore: Bool,
        isLoadingMore: Bool,
        loadMore: @escaping () -> Void,
    ) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(title).font(.headline)
                    if total > 0 {
                        Text("(\(total))").font(.headline).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 16)], spacing: 16) {
                    ForEach(items) { album in
                        AlbumCard(album: album) {
                            navigationCoordinator.navigateToAlbumSection(
                                albumId: album.id,
                                from: .artists,
                                selectionId: artistId,
                            )
                        }
                    }
                }
                .padding(.horizontal)

                if hasMore {
                    HStack {
                        Spacer()
                        if isLoadingMore {
                            ProgressView()
                        } else {
                            Button("Show more") { loadMore() }
                                .foregroundStyle(.green)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }

    /// A card view for displaying an album in the grid
    private struct AlbumCard: View {
        let album: Album
        let onTap: () -> Void

        @Environment(\.displayScale) private var displayScale

        var body: some View {
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 8) {
                    if let url = album.images.url(for: 150, scale: displayScale) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .empty:
                                ProgressView()
                                    .frame(width: 150, height: 150)
                            case let .success(image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 150, height: 150)
                                    .cornerRadius(8)
                            case .failure:
                                albumPlaceholder
                            @unknown default:
                                EmptyView()
                            }
                        }
                    } else {
                        albumPlaceholder
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(album.name)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .lineLimit(1)

                        Text(formatReleaseYear(album.releaseDate))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
        }

        private var albumPlaceholder: some View {
            Image(systemName: "music.note")
                .font(.system(size: 40))
                .foregroundStyle(.gray)
                .frame(width: 150, height: 150)
                .background(Color.gray.opacity(0.2))
                .cornerRadius(8)
        }

        private func formatReleaseYear(_ dateString: String?) -> String {
            guard let dateString else { return "" }
            return String(dateString.prefix(4))
        }
    }

    private func loadArtist() async {
        isLoadingArtist = true
        errorMessage = nil

        let token = await session.validAccessToken()
        do {
            let artistEntity = try await artistService.fetchArtistDetails(
                artistId: artistId,
                accessToken: token,
            )
            artist = artistEntity
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoadingArtist = false
    }

    private func loadTopTracks() async {
        isLoadingTopTracks = true
        do {
            let token = await session.validAccessToken()
            topTracks = try await artistService.fetchArtistTopTracks(artistId: artistId, accessToken: token)
        } catch {
            debugLog("ArtistDetailView", "fetchArtistTopTracks failed: \(error)")
        }
        isLoadingTopTracks = false
    }

    private func loadReleases() async {
        isLoadingReleases = true
        let token = await session.validAccessToken()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.fetchSection(group: "album", token: token) }
            group.addTask { await self.fetchSection(group: "single", token: token) }
            group.addTask { await self.fetchSection(group: "compilation", token: token) }
        }
        isLoadingReleases = false
    }

    private func fetchSection(group: String, token: String) async {
        do {
            let response = try await artistService.fetchArtistAlbums(artistId: artistId, accessToken: token, includeGroups: group, offset: 0)
            let newAlbums = response.albums.map { Album(from: $0) }
            switch group {
            case "album":
                albums = newAlbums; albumsTotal = response.total
                albumsOffset = newAlbums.count; albumsHasMore = response.hasMore
            case "single":
                singles = newAlbums; singlesTotal = response.total
                singlesOffset = newAlbums.count; singlesHasMore = response.hasMore
            case "compilation":
                compilations = newAlbums; compilationsTotal = response.total
                compilationsOffset = newAlbums.count; compilationsHasMore = response.hasMore
            default: break
            }
        } catch {
            debugLog("ArtistDetailView", "fetchSection(\(group)) failed: \(error)")
        }
    }

    private func loadMoreSection(group: String) async {
        let token = await session.validAccessToken()
        switch group {
        case "album":
            guard albumsHasMore, !isLoadingMoreAlbums else { return }
            isLoadingMoreAlbums = true
            do {
                let response = try await artistService.fetchArtistAlbums(artistId: artistId, accessToken: token, includeGroups: group, offset: albumsOffset)
                albums.append(contentsOf: response.albums.map { Album(from: $0) })
                albumsOffset += response.albums.count; albumsHasMore = response.hasMore
            } catch { debugLog("ArtistDetailView", "loadMore(album) failed: \(error)") }
            isLoadingMoreAlbums = false
        case "single":
            guard singlesHasMore, !isLoadingMoreSingles else { return }
            isLoadingMoreSingles = true
            do {
                let response = try await artistService.fetchArtistAlbums(artistId: artistId, accessToken: token, includeGroups: group, offset: singlesOffset)
                singles.append(contentsOf: response.albums.map { Album(from: $0) })
                singlesOffset += response.albums.count; singlesHasMore = response.hasMore
            } catch { debugLog("ArtistDetailView", "loadMore(single) failed: \(error)") }
            isLoadingMoreSingles = false
        case "compilation":
            guard compilationsHasMore, !isLoadingMoreCompilations else { return }
            isLoadingMoreCompilations = true
            do {
                let response = try await artistService.fetchArtistAlbums(artistId: artistId, accessToken: token, includeGroups: group, offset: compilationsOffset)
                compilations.append(contentsOf: response.albums.map { Album(from: $0) })
                compilationsOffset += response.albums.count; compilationsHasMore = response.hasMore
            } catch { debugLog("ArtistDetailView", "loadMore(compilation) failed: \(error)") }
            isLoadingMoreCompilations = false
        default: break
        }
    }

    private func unfollowArtist() {
        Task {
            do {
                let token = await session.validAccessToken()
                try await artistService.unfollowArtist(
                    artistId: artistId,
                    accessToken: token,
                )
                // Navigate away from the unfollowed artist
                navigationCoordinator.clearArtistSelection()
            } catch {
                errorMessage = String(localized: "error.unfollow_artist \(error.localizedDescription)")
            }
        }
    }

    private func followArtist() {
        Task {
            do {
                let token = await session.validAccessToken()
                try await artistService.followArtist(
                    artistId: artistId,
                    accessToken: token,
                )
            } catch {
                errorMessage = String(localized: "error.follow_artist \(error.localizedDescription)")
            }
        }
    }
}
