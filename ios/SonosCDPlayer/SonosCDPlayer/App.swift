import SwiftUI

struct Album: Decodable, Identifiable {
    let title: String
    let artist: String?
    let album_art_uri: String?
    let uri: String?
    var id: String { (uri ?? title) + (artist ?? "") }
}
struct AlbumList: Decodable { let albums: [Album] }
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
    var errorDescription: String? { message }
}

@MainActor @Observable final class Player {
    var albums: [Album] = []
    var discs: [Disc] = []
    var currentDisc: String?
    var status: PlayerStatus?
    var editingVolume = false
    var busy = false
    var connected = false
    var error: String?
    var notice: String?
    var staleQueue = false
    var address = UserDefaults.standard.string(forKey: "server") ?? "http://192.168.1.100:8000"

    func request(_ path: String, method: String = "GET", query: [URLQueryItem] = []) async throws -> Data {
        guard var url = URLComponents(string: address), ["http", "https"].contains(url.scheme ?? ""), url.host != nil else {
            throw APIError(message: "Enter a server address such as http://192.168.1.100:8000")
        }
        url.path = path
        url.queryItems = query.isEmpty ? nil : query
        guard let endpoint = url.url else { throw APIError(message: "Invalid server address") }
        var req = URLRequest(url: endpoint)
        req.httpMethod = method
        req.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError(message: "No server response") }
        guard (200..<300).contains(http.statusCode) else {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let detail = body?["detail"]
            let message = (detail as? String) ?? "The server could not complete this action (\(http.statusCode))."
            if http.statusCode == 409 && message.contains("resync") { staleQueue = true }
            throw APIError(message: message)
        }
        return data
    }
    func refresh(library: Bool = false, silent: Bool = false) async {
        guard !busy && !editingVolume else { return }
        busy = true
        defer { busy = false }
        do {
            if library {
                let data = try await request("/albums")
                albums = try JSONDecoder().decode(AlbumList.self, from: data).albums
            }
            try await refreshPlayback()
            connected = true
        } catch {
            connected = false
            if !silent { self.error = error.localizedDescription }
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
    func action(_ path: String, method: String = "POST", query: [URLQueryItem] = [], success: String? = nil) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await request(path, method: method, query: query)
            notice = success
            try await refreshPlayback()
            connected = true
        } catch { self.error = error.localizedDescription }
    }
    func load(_ album: Album) async {
        var query = [URLQueryItem(name: "title", value: album.title)]
        if let artist = album.artist, !artist.isEmpty { query.append(URLQueryItem(name: "artist", value: artist)) }
        await action("/discs/load", query: query, success: "Loaded \(album.title)")
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
    @State private var search = ""
    @State private var settings = false
    @State private var resync = false
    var filtered: [Album] {
        player.albums.filter { search.isEmpty || ($0.title + " " + ($0.artist ?? "")).localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        TabView {
            NavigationStack {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("GARAGE", systemImage: "hifispeaker.fill").font(.caption.weight(.bold)).foregroundStyle(.orange)
                            Text("Your collection.\nReady to play.").font(.largeTitle.bold())
                            Text("Load an album into the tray, then choose a disc to start listening.").foregroundStyle(.secondary)
                        }.padding(.vertical, 14)
                    }
                    Section("Albums · \(filtered.count)") {
                        ForEach(filtered) { album in
                            HStack(spacing: 14) {
                                Artwork(path: album.album_art_uri)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(album.title).font(.headline)
                                    Text(album.artist ?? "Unknown artist").font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button { Task { await player.load(album) } } label: {
                                    Image(systemName: "plus.circle.fill").font(.title2)
                                }.buttonStyle(.borderless).disabled(player.busy || player.staleQueue)
                                    .accessibilityLabel("Load \(album.title)")
                            }.padding(.vertical, 4)
                        }
                        if filtered.isEmpty {
                            Text(player.albums.isEmpty ? "Pull down to connect and load your library." : "No matching albums.").foregroundStyle(.secondary)
                        }
                    }
                }.searchable(text: $search, prompt: "Album or artist")
                    .navigationTitle("CD Player")
                    .toolbar { connectionToolbar }
                    .refreshable { await player.refresh(library: true) }
            }.tabItem { Label("Library", systemImage: "square.stack") }
            NavigationStack {
                List {
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
                VStack(spacing: 24) {
                    Spacer()
                    Image(systemName: "opticaldisc.fill").font(.system(size: 120)).foregroundStyle(.orange.gradient)
                    VStack(spacing: 8) {
                        Text(player.status?.track["title"].flatMap { $0.isEmpty ? nil : $0 } ?? "Nothing playing").font(.title.bold()).multilineTextAlignment(.center)
                        Text(player.status?.track["artist"] ?? "Garage").foregroundStyle(.secondary)
                        Text(player.status?.track["album"] ?? "").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text(player.status?.transport["current_transport_state"]?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Not connected").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    PlaybackControls(player: player)
                    Spacer()
                }.padding(24).frame(maxWidth: .infinity).navigationTitle("Now playing").toolbar { connectionToolbar }
            }.tabItem { Label("Now playing", systemImage: "waveform") }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let notice = player.notice {
                HStack { Text(notice).font(.caption); Spacer(); Button("Dismiss", systemImage: "xmark") { player.notice = nil }.labelStyle(.iconOnly) }.padding(10).background(.thinMaterial)
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
        .alert("Couldn’t complete that", isPresented: Binding(get: { player.error != nil }, set: { if !$0 { player.error = nil } })) {
            Button("OK") { player.error = nil }
        } message: { Text(player.error ?? "") }
        .confirmationDialog("Reset disc tracking?", isPresented: $resync, titleVisibility: .visible) {
            Button("Forget loaded discs", role: .destructive) { Task { await player.action("/discs/resync") } }
        } message: { Text("This forgets the tray’s disc assignments. It does not remove tracks from Sonos.") }
    }
    @ToolbarContentBuilder var connectionToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 5) {
                Circle().fill(player.connected ? Color.green : Color.gray).frame(width: 6, height: 6)
                Text(player.connected ? "Garage" : "Offline").font(.caption).fixedSize()
                if player.busy { ProgressView().controlSize(.mini) }
            }
        }
        ToolbarItem(placement: .topBarTrailing) { Button("Settings", systemImage: "gearshape") { settings = true } }
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
            VStack(spacing: 8) {
                HStack {
                    Text("Garage volume").font(.subheadline)
                    Spacer()
                    Text(player.status?.muted == true ? "Muted · \(Int(volume))%" : "\(Int(volume))%")
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: $volume, in: 0...100, step: 1) { editing in
                        player.editingVolume = editing
                        if !editing {
                            let level = Int(volume)
                            Task {
                                await player.action("/volume", query: [URLQueryItem(name: "level", value: String(level))])
                                volume = Double(player.status?.volume ?? level)
                            }
                        }
                    }.accessibilityLabel("Garage volume").accessibilityValue("\(Int(volume)) percent")
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
        AsyncImage(url: path.flatMap { URL(string: $0, relativeTo: URL(string: "http://192.168.1.85:1400")) }) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack { Color.orange.opacity(0.12); Image(systemName: "opticaldisc").font(.title).foregroundStyle(.orange) }
        }.frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
struct SettingsView: View {
    let player: Player
    @State private var address = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Backend address") {
                    TextField("http://192.168.1.100:8000", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section { Text("Connect to the same local network as your NAS and Garage speaker. Allow Local Network access when iOS asks.") }
            }.navigationTitle("Connection")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            player.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
                            UserDefaults.standard.set(player.address, forKey: "server")
                            player.albums = []; player.discs = []; player.status = nil; player.connected = false
                            dismiss()
                            Task { await player.refresh(library: true) }
                        }.disabled(player.busy)
                    }
                }
        }.onAppear { address = player.address }
    }
}
