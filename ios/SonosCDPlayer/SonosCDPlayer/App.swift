import SwiftUI

struct Album: Decodable, Identifiable {
    let title: String
    let artist: String?
    let album_art_uri: String?
    let uri: String?
    var id: String { (uri ?? title) + (artist ?? "") }
}
enum LibrarySort: String, CaseIterable, Identifiable {
    case artist, album
    var id: String { rawValue }
    var title: String { self == .artist ? "Artist" : "Album name" }
    func precedes(_ lhs: Album, _ rhs: Album) -> Bool {
        let leftArtist = lhs.artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rightArtist = rhs.artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        let left = leftArtist.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown artist"
        let right = rightArtist.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown artist"
        let primary = (self == .artist ? left : lhs.title).localizedStandardCompare(self == .artist ? right : rhs.title)
        if primary != .orderedSame { return primary == .orderedAscending }
        let secondary = (self == .artist ? lhs.title : left).localizedStandardCompare(self == .artist ? rhs.title : right)
        if secondary != .orderedSame { return secondary == .orderedAscending }
        return lhs.id < rhs.id
    }
}

struct LibrarySortSelector: View {
    @Binding var selection: LibrarySort
    var body: some View {
        HStack {
            Text("Sort by").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            Picker("Sort by", selection: $selection) {
                ForEach(LibrarySort.allCases) { order in Text(order.title).tag(order) }
            }.pickerStyle(.menu).tint(.orange)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }.fixedSize(horizontal: true, vertical: false)
            .frame(minHeight: 44)
    }
}

struct AlbumList: Decodable { let albums: [Album] }
struct SpeakerInfo: Decodable { let name: String }
struct ListeningArea: Decodable, Identifiable {
    let id: String
    let name: String
}
struct ListeningAreaResponse: Decodable {
    let area: String
    let areas: [ListeningArea]
}
struct Disc: Decodable, Identifiable {
    let id: String
    let album: String
    let artist: String?
    let queue_start: Int
    let queue_end: Int
    let tracks_added: Int
}
struct DiscList: Decodable {
    let discs: [Disc]
    let current_disc_id: String?
    let queue_size: Int
}
struct PlayerStatus: Decodable {
    let track: [String: String]
    let transport: [String: String]
    let volume: Int?
    let muted: Bool?
}
struct APIError: LocalizedError {
    let message: String
    var statusCode: Int? = nil
    var errorDescription: String? { message }
}
struct CDSet: Decodable, Identifiable {
    struct Entry: Decodable { let title: String; let artist: String? }
    let id: String
    let name: String
    let albums: [Entry]
}
struct CDSetList: Decodable { let sets: [CDSet] }

@MainActor @Observable final class Player {
    static let demoAddress = "https://not-streaming-demo.dbsand.chatgpt.site"
    private static let libraryRefreshInterval: TimeInterval = 24 * 60 * 60
    private static let lastLibraryRefreshKey = "lastLibraryRefresh"
    var albums: [Album] = []
    var discs: [Disc] = []
    var currentDisc: String?
    var status: PlayerStatus?
    var draggingAlbum = false
    var editingVolume = false
    var busy = false
    var connected = false
    var error: String?
    var notice: String?
    var staleQueue = false
    var cdSets: [CDSet] = []
    var setsAvailable = false
    var setOperation: String?
    var speakerName: String?
    var listeningArea: String?
    var listeningAreas: [ListeningArea] = []
    var changingArea = false
    var demoMode = (UserDefaults.standard.object(forKey: "demoMode") as? Bool) ?? true
    var address = UserDefaults.standard.string(forKey: "server") ?? "http://192.168.1.100:8000"
    var activeAddress: String { demoMode ? Self.demoAddress : address }
    var speakerDisplayName: String {
        if demoMode { return "Demo" }
        if listeningAreas.count > 1,
           let area = listeningAreas.first(where: { $0.id == listeningArea }) { return area.name }
        let trimmed = speakerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Sonos" : trimmed
    }
    private var libraryLoaded = false
    private var artworkPrefetchTask: Task<Void, Never>?
    private var libraryRefreshDue: Bool {
        let lastRefresh = UserDefaults.standard.double(forKey: Self.lastLibraryRefreshKey)
        let now = Date().timeIntervalSince1970
        return lastRefresh == 0 || now < lastRefresh || now - lastRefresh >= Self.libraryRefreshInterval
    }
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        // Give the first Local Network permission prompt time to complete.
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()
    private let setSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }()

    func resetLibrary() {
        artworkPrefetchTask?.cancel()
        artworkPrefetchTask = nil
        albums = []
        libraryLoaded = false
    }

    private func prefetchArtwork() {
        artworkPrefetchTask?.cancel()
        let paths = albums.map(\.album_art_uri)
        artworkPrefetchTask = Task(priority: .utility) {
            await AlbumArtwork.prefetch(paths)
        }
    }

    func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [], longRunning: Bool = false, body: Data? = nil) async throws -> Data {
        guard var url = URLComponents(string: activeAddress), ["http", "https"].contains(url.scheme ?? ""), url.host != nil else {
            throw APIError(message: "Enter a server address such as http://192.168.1.100:8000")
        }
        url.path = (demoMode ? "/api" : "") + path
        url.queryItems = query.isEmpty ? nil : query
        // URLComponents leaves literal + signs intact, but the backend decodes
        // them as spaces in query parameters. Preserve album and artist names.
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let endpoint = url.url else { throw APIError(message: "Invalid server address") }
        var req = URLRequest(url: endpoint)
        req.httpMethod = method
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        req.timeoutInterval = longRunning ? 300 : 15
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await (longRunning ? setSession : session).data(for: req)
        } catch let networkError as URLError {
            switch networkError.code {
            case .notConnectedToInternet, .timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .dataNotAllowed:
                connected = false
                if demoMode {
                    throw APIError(message: "Could not reach the demonstration service. Check your internet connection and try again.")
                }
                throw APIError(message: "Could not reach \(address). Connect to the same Wi-Fi network as your NAS, then enable Not Streaming in Settings → Privacy & Security → Local Network. Check the backend address in Connection settings if it still won’t connect.")
            default:
                throw networkError
            }
        }
        guard let http = response as? HTTPURLResponse else { throw APIError(message: "No server response") }
        guard (200..<300).contains(http.statusCode) else {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let detail = body?["detail"]
            let message = (detail as? String) ?? "The server could not complete this action (\(http.statusCode))."
            if http.statusCode == 409 && message.contains("resync") { staleQueue = true }
            throw APIError(message: message, statusCode: http.statusCode)
        }
        return data
    }
    func refresh(library: Bool = false, silent: Bool = false) async {
        guard !busy && !editingVolume && !draggingAlbum else { return }
        busy = true
        defer { busy = false }
        do {
            let reloadLibrary = library || !libraryLoaded || libraryRefreshDue
            try await refreshListeningArea()
            if !demoMode && (reloadLibrary || speakerName == nil) {
                await refreshSpeakerInfo()
            }
            try await refreshSets()
            if reloadLibrary {
                let data = try await request("/albums")
                albums = try JSONDecoder().decode(AlbumList.self, from: data).albums
                libraryLoaded = true
                UserDefaults.standard.set(Date().timeIntervalSince1970,
                                          forKey: Self.lastLibraryRefreshKey)
                prefetchArtwork()
            }
            try await refreshPlayback()
            connected = true
        } catch {
            connected = false
            if !silent { self.error = error.localizedDescription }
        }
    }
    private func refreshSpeakerInfo() async {
        guard let data = try? await request("/speaker"),
              let info = try? JSONDecoder().decode(SpeakerInfo.self, from: data) else { return }
        speakerName = info.name
    }
    private func refreshListeningArea() async throws {
        if demoMode {
            listeningArea = nil; listeningAreas = []
            return
        }
        do {
            let data = try await request("/listening-area")
            let response = try JSONDecoder().decode(ListeningAreaResponse.self, from: data)
            listeningArea = response.area
            listeningAreas = response.areas
        } catch let error as APIError where error.statusCode == 404 {
            listeningArea = nil; listeningAreas = []
        }
    }
    func selectListeningArea(_ area: String) async {
        guard !busy, !editingVolume, !draggingAlbum, area != listeningArea else { return }
        busy = true; changingArea = true
        defer { busy = false; changingArea = false }
        do {
            let body = try JSONEncoder().encode(["area": area])
            let data = try await request("/listening-area", method: "PUT", longRunning: true, body: body)
            let response = try JSONDecoder().decode(ListeningAreaResponse.self, from: data)
            listeningArea = response.area; listeningAreas = response.areas
            await refreshSpeakerInfo()
            try await refreshPlayback()
            connected = true
            notice = "\(speakerDisplayName) selected. Press Play to start music."
        } catch {
            self.error = error.localizedDescription
            // A timeout can occur after the server has committed the switch.
            try? await refreshListeningArea()
            await refreshSpeakerInfo()
            try? await refreshPlayback()
        }
    }
    private func refreshSets() async throws {
        do {
            let data = try await request("/cd-sets")
            cdSets = try JSONDecoder().decode(CDSetList.self, from: data).sets
            setsAvailable = true
        } catch let apiError as APIError where apiError.statusCode == 404 {
            // Older backends remain usable while the CD Sets update is deployed.
            setsAvailable = false
            cdSets = []
        }
    }
    func saveSet(name: String, replacing setID: String? = nil) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            if let setID {
                _ = try await request("/cd-sets/\(setID)", method: "PUT")
            } else {
                _ = try await request("/cd-sets", method: "POST", query: [URLQueryItem(name: "name", value: name)])
            }
            try await refreshSets()
            notice = "Saved \(name)"
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func addAlbum(_ album: Album, to cdSet: CDSet?, newSetName: String = "") async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        let albumQuery = [
            URLQueryItem(name: "title", value: album.title),
            URLQueryItem(name: "artist", value: album.artist)
        ]
        do {
            let destinationName: String
            if let cdSet {
                _ = try await request("/cd-sets/\(cdSet.id)/albums", method: "POST", query: albumQuery)
                destinationName = cdSet.name
            } else {
                destinationName = newSetName.trimmingCharacters(in: .whitespacesAndNewlines)
                _ = try await request("/cd-sets", method: "POST", query: [URLQueryItem(name: "name", value: destinationName)] + albumQuery)
            }
            try await refreshSets()
            notice = "Added \(album.title) to \(destinationName)"
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func deleteSet(_ cdSet: CDSet) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await request("/cd-sets/\(cdSet.id)", method: "DELETE")
            try await refreshSets()
        } catch { self.error = error.localizedDescription }
    }
    func playSet(_ cdSet: CDSet, shuffle: Bool) async {
        await replaceCDs(path: "/cd-sets/\(cdSet.id)/play", query: [URLQueryItem(name: "shuffle", value: String(shuffle))], label: "Loading \(cdSet.name)…")
    }
    func shuffleCDs() async {
        await replaceCDs(path: "/discs/shuffle", label: "Shuffling CDs…")
    }
    private func replaceCDs(path: String, query: [URLQueryItem] = [], label: String) async {
        guard !busy && !draggingAlbum else { return }
        busy = true
        setOperation = label
        discs = []; currentDisc = nil; status = nil
        defer { busy = false; setOperation = nil }
        do {
            _ = try await request(path, method: "POST", query: query, longRunning: true)
            try await refreshPlayback()
            connected = true
            notice = "CDs loaded and playing"
        } catch {
            self.error = "\(error.localizedDescription) If loading was interrupted, refresh to check the queue before trying again."
            // Recover the actual queue if only the response was lost.
            try? await refreshPlayback()
        }
    }
    private func refreshPlayback() async throws {
        let statusData = try await request("/status")
        status = try JSONDecoder().decode(PlayerStatus.self, from: statusData)
        let discData = try await request("/discs")
        let result = try JSONDecoder().decode(DiscList.self, from: discData)
        discs = result.discs
        currentDisc = result.current_disc_id
        staleQueue = false
    }
    @discardableResult
    func action(_ path: String, method: String = "POST", query: [URLQueryItem] = [], success: String? = nil) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            _ = try await request(path, method: method, query: query)
            notice = success
            try await refreshPlayback()
            connected = true
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func isLoaded(_ album: Album) -> Bool { loadedDisc(for: album) != nil }
    func loadedDisc(for album: Album) -> Disc? {
        discs.first { $0.album.compare(album.title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame && ($0.artist ?? "").compare(album.artist ?? "", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }
    @discardableResult
    func load(_ album: Album, play: Bool = false) async -> Bool {
        guard !staleQueue else { return false }
        if let disc = loadedDisc(for: album) {
            return play ? await action("/discs/\(disc.id)/play", success: "Playing \(album.title)") : false
        }
        var query = [URLQueryItem(name: "title", value: album.title)]
        if let artist = album.artist, !artist.isEmpty { query.append(URLQueryItem(name: "artist", value: artist)) }
        return await action(play ? "/play-album" : "/discs/load", query: query, success: "\(play ? "Playing" : "Loaded") \(album.title)")
    }
}

@main struct SonosCDPlayerApp: App {
    @State private var player = Player()
    var body: some Scene {
        WindowGroup { ContentView(player: player).tint(.orange).preferredColorScheme(.dark) }
    }
}

struct ContentView: View {
    @Bindable var player: Player
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var search = ""
    @AppStorage("cdLibrarySort") private var librarySort: LibrarySort = .album
    @State private var settings = false
    @State private var showingHelp = false
    @State private var resync = false
    var filtered: [Album] {
        player.albums.filter { search.isEmpty || ($0.title + " " + ($0.artist ?? "")).localizedCaseInsensitiveContains(search) }.sorted(by: librarySort.precedes)
    }
    var body: some View {
        Group {
            if UIDevice.current.userInterfaceIdiom == .pad && sizeClass != .compact {
                VintageChangerView(
                    player: player,
                    settings: { settings = true },
                    help: { showingHelp = true },
                    resync: { resync = true }
                )
            } else {
                phoneTabs
            }
        }
        .task { await player.refresh(library: true) }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                await player.refresh(silent: true)
            }
        }
        .sheet(isPresented: $settings) { SettingsView(player: player) }
        .sheet(isPresented: $showingHelp) { HelpView() }
        .alert("Couldn’t complete that", isPresented: Binding(get: { player.error != nil }, set: { if !$0 { player.error = nil } })) {
            Button("OK") { player.error = nil }
        } message: { Text(player.error ?? "") }
        .confirmationDialog("Reset disc tracking?", isPresented: $resync, titleVisibility: .visible) {
            Button("Forget loaded discs", role: .destructive) { Task { await player.action("/discs/resync") } }
        } message: { Text("This forgets the tray’s disc assignments. It does not remove tracks from Sonos.") }
    }
    private var phoneTabs: some View {
        TabView {
            NavigationStack {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(player.demoMode ? "DEMO LIBRARY" : player.speakerDisplayName.uppercased(), systemImage: player.demoMode ? "sparkles" : "hifispeaker.fill")
                                .font(.caption.weight(.bold)).foregroundStyle(.orange)
                            Text("Your collection.\nReady to play.").font(.largeTitle.bold())
                            Text("Load an album into the tray, then choose a disc to start listening.").foregroundStyle(.secondary)
                        }.padding(.vertical, 14)
                    }
                    if player.demoMode {
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("You’re exploring the demo", systemImage: "sparkles")
                                    .font(.headline).foregroundStyle(.orange)
                                Text("This is a fictional collection. Playback controls are simulated and no audio is sent anywhere.")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                Button("Connect to your system") { settings = true }
                                    .font(.subheadline.weight(.semibold))
                            }.padding(.vertical, 4)
                        }
                    }
                    Section {
                        LibrarySortSelector(selection: $librarySort).disabled(player.draggingAlbum)
                    }
                    Section("Albums · \(filtered.count)") {
                        ForEach(filtered) { album in
                            HStack(spacing: 14) {
                                Artwork(path: album.album_art_uri).saturation(player.isLoaded(album) ? 0 : 1).opacity(player.isLoaded(album) ? 0.4 : 1)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(album.title).font(.headline)
                                    Text(album.artist ?? "Unknown artist").font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button { Task { await player.load(album) } } label: {
                                    Image(systemName: player.isLoaded(album) ? "checkmark.circle.fill" : "plus.circle.fill").font(.title2)
                                }.buttonStyle(.borderless).disabled(player.busy || player.staleQueue || player.isLoaded(album))
                                    .accessibilityLabel("Load \(album.title)")
                            }.padding(.vertical, 4)
                        }
                        if filtered.isEmpty {
                            Text(player.albums.isEmpty ? "Pull down to connect and load your library." : "No matching albums.").foregroundStyle(.secondary)
                        }
                    }
                }.searchable(text: $search, prompt: "Album or artist")
                    .scrollDismissesKeyboard(.interactively)
                    .navigationTitle("Not Streaming")
                    .toolbar { connectionToolbar }
                    .refreshable { await player.refresh(library: true) }
            }.tabItem { Label("Library", systemImage: "square.stack") }
            NavigationStack {
                List {
                    Section { CDSetControls(player: player) }
                    if player.staleQueue {
                        Section {
                            Text("The Sonos queue changed. Reset disc tracking to use the tray again. Your queued music will stay in place.")
                            Button("Reset disc tracking") { resync = true }
                        }
                    }
                    if player.discs.isEmpty {
                        ContentUnavailableView("The tray is empty", systemImage: "opticaldisc", description: Text("Add an album from Library. Loading keeps your existing music in the queue."))
                    }
                    ForEach(Array(player.discs.enumerated()), id: \.element.id) { index, disc in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label("DISC \(index + 1)", systemImage: "opticaldisc").font(.caption.bold()).foregroundStyle(.orange)
                                Spacer()
                                if disc.id == player.currentDisc { Label("Selected", systemImage: "speaker.wave.2.fill").font(.caption).foregroundStyle(.orange) }
                            }
                            Text(disc.album).font(.title2.bold())
                            Text(disc.artist ?? "Unknown artist").foregroundStyle(.secondary)
                            HStack {
                                Text("\(disc.tracks_added) tracks").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Play", systemImage: "play.fill") { Task { await player.action("/discs/\(disc.id)/play") } }
                                Button("Eject", systemImage: "eject.fill") { Task { await player.action("/discs/\(disc.id)", method: "DELETE") } }
                            }.buttonStyle(.borderless).disabled(player.busy || player.staleQueue)
                        }.padding(.vertical, 10)
                    }
                }.navigationTitle("Disc tray")
                    .toolbar { connectionToolbar }
                    .refreshable { await player.refresh() }
            }.tabItem { Label("Disc tray", systemImage: "opticaldisc") }
            NavigationStack {
                ScrollView {
                    VStack(spacing: 20) {
                        Image(systemName: "opticaldisc.fill").font(.system(size: 88)).foregroundStyle(.orange.gradient)
                        VStack(spacing: 8) {
                            Text(player.status?.track["title"].flatMap { $0.isEmpty ? nil : $0 } ?? "Nothing playing").font(.title.bold()).multilineTextAlignment(.center)
                            Text(player.status?.track["artist"] ?? (player.demoMode ? "Demo player" : player.speakerDisplayName)).foregroundStyle(.secondary)
                            Text(player.status?.track["album"] ?? "").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text(player.status?.transport["current_transport_state"]?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Not connected").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                        PlaybackControls(player: player)
                    }.padding(24).frame(maxWidth: .infinity)
                }
                .navigationTitle("Now playing")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { connectionToolbar }
            }.tabItem { Label("Now playing", systemImage: "waveform") }
        }
    }
    @ToolbarContentBuilder var connectionToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 5) {
                Circle().fill(player.connected ? Color.green : Color.gray).frame(width: 6, height: 6)
                Text(player.demoMode ? "Demo" : (player.connected ? player.speakerDisplayName : "Offline")).font(.caption).fixedSize()
                if player.busy { ProgressView().controlSize(.mini) }
            }
        }
        ToolbarItem(placement: .topBarTrailing) { Button("Settings", systemImage: "gearshape") { settings = true } }
    }
}

private struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    private let tasks = [
        HelpTask(
            title: "Loading a CD",
            icon: "arrow.right.circle.fill",
            steps: [
                "Find the album in CD Library.",
                "Drag its cover onto the player and release when the player outline turns amber.",
                "To load it and start listening immediately, tap the cover and choose Play now."
            ]
        ),
        HelpTask(
            title: "Unloading a CD",
            icon: "eject.fill",
            steps: [
                "Find the CD in the player’s Disc Magazine.",
                "Drag its title onto the collection and release when the collection outline turns amber.",
                "You can also use the eject button beside that CD."
            ]
        ),
        HelpTask(
            title: "Saving a CD Set",
            icon: "square.and.arrow.down.fill",
            steps: [
                "Load the CDs you want into the Disc Magazine.",
                "Choose Save CD Set on the player.",
                "Create a named set, or select an existing set to overwrite, then save. Playback continues while the set is saved."
            ]
        ),
        HelpTask(
            title: "Choosing a Set to Play",
            icon: "play.square.stack.fill",
            steps: [
                "Choose CD Sets at the top of the collection.",
                "Drag a saved set onto the player, or select it and choose Play now.",
                "The set replaces the current magazine and starts playing."
            ]
        )
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(tasks) { task in
                        HelpTaskCard(task: task)
                    }
                }
                .padding(20)
            }
            .background(Color(red: 0.075, green: 0.08, blue: 0.082))
            .navigationTitle("How to Use the Player")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct HelpTask: Identifiable {
    let title: String
    let icon: String
    let steps: [String]
    var id: String { title }
}

private struct HelpTaskCard: View {
    let task: HelpTask

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(task.title, systemImage: task.icon)
                .font(.headline)
                .foregroundStyle(Color(red: 1, green: 0.66, blue: 0.25))
            VStack(alignment: .leading, spacing: 11) {
                ForEach(Array(task.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit().weight(.bold))
                            .foregroundStyle(.black)
                            .frame(width: 22, height: 22)
                            .background(Color(red: 1, green: 0.66, blue: 0.25), in: Circle())
                        Text(step)
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.84))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.11), lineWidth: 1))
    }
}

struct ListeningAreaSelector: View {
    @Bindable var player: Player
    var body: some View {
        if !player.demoMode && player.listeningAreas.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Listen in").font(.subheadline).foregroundStyle(.secondary)
                    if player.changingArea { ProgressView().controlSize(.small) }
                }
                Picker("Listening area", selection: Binding(
                    get: { player.listeningArea ?? "downstairs" },
                    set: { area in Task { await player.selectListeningArea(area) } }
                )) {
                    ForEach(player.listeningAreas) { area in Text(area.name).tag(area.id) }
                }.pickerStyle(.segmented)
                    .disabled(player.busy || player.editingVolume || player.draggingAlbum || player.staleQueue)
                Text(player.changingArea ? "Changing speakers…" : "Changing rooms stops music. Press Play when ready.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct PlaybackControls: View {
    @Bindable var player: Player
    @State private var volume = 0.0
    private var transport: String { player.status?.transport["current_transport_state"] ?? "" }
    private var playing: Bool { transport == "PLAYING" }
    private var canToggle: Bool {
        ["PLAYING", "PAUSED_PLAYBACK", "STOPPED"].contains(transport)
        && !(player.status?.track["uri"] ?? "").isEmpty
    }
    var body: some View {
        VStack(spacing: 28) {
            ListeningAreaSelector(player: player)
            HStack(spacing: 40) {
                Button { Task { await player.action("/discs/previous") } } label: {
                    Label("Previous disc", systemImage: "backward.end.fill")
                }.disabled(player.busy || player.discs.isEmpty || player.staleQueue)
                Button { Task { await player.action(playing ? "/pause" : "/play") } } label: {
                    Label(playing ? "Pause" : "Resume", systemImage: playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 64))
                }.disabled(player.busy || !canToggle)
                Button { Task { await player.action("/discs/next") } } label: {
                    Label("Next disc", systemImage: "forward.end.fill")
                }.disabled(player.busy || player.discs.isEmpty || player.staleQueue)
            }.labelStyle(.iconOnly).font(.title)
            HStack(spacing: 32) {
                Button("Previous track", systemImage: "backward.fill") { Task { await player.action("/tracks/previous") } }
                Button("Next track", systemImage: "forward.fill") { Task { await player.action("/tracks/next") } }
            }.font(.subheadline).disabled(player.busy || (player.status?.track["uri"] ?? "").isEmpty)
            VStack(spacing: 8) {
                HStack {
                    Text("\(player.demoMode ? "Sonos Speaker" : player.speakerDisplayName) volume").font(.subheadline)
                    Spacer()
                    Text(player.status?.muted == true ? "Muted · \(Int(volume))%" : "\(Int(volume))%")
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    VolumeSlider(value: $volume) { editing in
                        player.editingVolume = editing
                        if !editing {
                            let level = Int(volume)
                            Task {
                                await player.action("/volume", query: [URLQueryItem(name: "level", value: String(level))])
                                volume = Double(player.status?.volume ?? level)
                            }
                        }
                    }.accessibilityLabel("\(player.demoMode ? "Sonos Speaker" : player.speakerDisplayName) volume").accessibilityValue("\(Int(volume)) percent")
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }.disabled(player.busy || player.status?.volume == nil)
                if player.status?.volume == nil {
                    Text("Update the server to enable volume controls.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { volume = Double(player.status?.volume ?? 0) }
        .onChange(of: player.status?.volume) { _, value in
            if !player.editingVolume { volume = Double(value ?? 0) }
        }
        .onDisappear { player.editingVolume = false }
    }
}

struct Artwork: View {
    let path: String?
    var body: some View {
        CachedArtworkImage(url: AlbumArtwork.url(for: path)) {
            ZStack { Color.orange.opacity(0.12); Image(systemName: "opticaldisc").font(.title).foregroundStyle(.orange) }
        }.scaledToFill().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
struct SettingsView: View {
    let player: Player
    @State private var address = ""
    @State private var demoMode = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Backend address") {
                    Toggle("Demo", isOn: $demoMode)
                    TextField("http://192.168.1.100:8000", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(demoMode)
                    if demoMode {
                        Text("Uses a fictional music library and simulated playback. Your backend address is preserved.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text(demoMode ? "Demo mode does not connect to your NAS or Sonos system." : "Connect to the same local network as your NAS and Sonos speaker. Allow Local Network access when iOS asks.")
                }
            }.navigationTitle("Connection")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            player.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
                            player.demoMode = demoMode
                            UserDefaults.standard.set(player.address, forKey: "server")
                            UserDefaults.standard.set(player.demoMode, forKey: "demoMode")
                            player.resetLibrary(); player.discs = []; player.status = nil; player.connected = false
                            player.speakerName = nil
                            player.listeningArea = nil; player.listeningAreas = []
                            player.cdSets = []; player.setsAvailable = false
                            dismiss()
                            Task { await player.refresh(library: true) }
                        }.disabled(player.busy)
                    }
                }
        }.onAppear {
            address = player.address
            demoMode = player.demoMode
        }
    }
}

struct CDSetControls: View {
    @Bindable var player: Player
    var showSetBrowser = true
    @AppStorage("shuffleCDSets") private var shuffle = false
    @State private var saving = false
    @State private var name = ""
    @State private var replacingID = ""
    @State private var deleting: CDSet?
    private var selectedSet: CDSet? { player.cdSets.first { $0.id == replacingID } }
    private var validSave: Bool {
        !player.busy && !player.draggingAlbum && !player.staleQueue && !player.discs.isEmpty &&
        (replacingID.isEmpty ? !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 80 : selectedSet != nil)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    name = ""; replacingID = ""; saving = true
                } label: {
                    Label("Save CD Set", systemImage: "plus.circle").font(.headline).frame(minHeight: 44)
                }.disabled(player.busy || player.draggingAlbum || !player.setsAvailable || player.discs.isEmpty || player.staleQueue)
                Spacer()
                Menu {
                    Toggle("Shuffle CDs when loading", isOn: $shuffle)
                    Button("Shuffle Loaded CDs & Play", systemImage: "shuffle") { Task { await player.shuffleCDs() } }
                        .disabled(player.discs.count < 2 || player.staleQueue)
                    if showSetBrowser {
                        Section("Play a saved set") {
                            ForEach(player.cdSets) { cdSet in
                                Button(cdSet.name) { Task { await player.playSet(cdSet, shuffle: shuffle) } }
                            }
                        }
                        Menu("Delete a set") {
                            ForEach(player.cdSets) { cdSet in
                                Button(cdSet.name, role: .destructive) { deleting = cdSet }
                            }
                        }.disabled(player.cdSets.isEmpty)
                    }
                } label: {
                    Image(systemName: "shuffle").frame(width: 44, height: 44)
                }.accessibilityLabel("CD playback options")
                    .disabled(player.busy || player.draggingAlbum || !player.setsAvailable)
                if player.setOperation != nil { ProgressView() }
            }
            if let operation = player.setOperation {
                Text(operation).font(.caption).foregroundStyle(.secondary)
            } else if !player.setsAvailable {
                Text("Update the NAS backend to enable CD Sets.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Delete \(deleting?.name ?? "set")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete this set", role: .destructive) {
                if let cdSet = deleting { Task { await player.deleteSet(cdSet) } }
                deleting = nil
            }
        } message: { Text("The loaded CDs and current playback will stay as they are.") }
        .sheet(isPresented: $saving) {
            NavigationStack {
                Form {
                    Section("Save to") {
                        Picker("CD Set", selection: $replacingID) {
                            Text("Create a new set").tag("")
                            ForEach(player.cdSets) { cdSet in Text(cdSet.name).tag(cdSet.id) }
                        }
                        if replacingID.isEmpty {
                            TextField("New set name", text: $name)
                        }
                    }
                    Section {
                        Text(replacingID.isEmpty
                            ? "Save the \(player.discs.count) loaded CDs in their current order."
                            : "Replace the CDs saved in \(selectedSet?.name ?? "this set") with the \(player.discs.count) currently loaded CDs.")
                        Text("Playback will continue.").foregroundStyle(.secondary)
                    }
                }.navigationTitle("Save CD Set")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { saving = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(replacingID.isEmpty ? "Save" : "Overwrite") {
                                let savedName = selectedSet?.name ?? name.trimmingCharacters(in: .whitespacesAndNewlines)
                                let savedID = replacingID.isEmpty ? nil : replacingID
                                Task {
                                    if await player.saveSet(name: savedName, replacing: savedID) { saving = false }
                                }
                            }.disabled(!validSave)
                        }
                    }
            }.presentationDetents([.medium, .large])
                .alert("Couldn’t save set", isPresented: Binding(get: { player.error != nil }, set: { if !$0 { player.error = nil } })) {
                    Button("OK") { player.error = nil }
                } message: { Text(player.error ?? "") }
        }
    }
}
