import SwiftUI
import UIKit

private let amber = Color(red: 1, green: 0.66, blue: 0.25)
private let ink = Color(red: 0.08, green: 0.085, blue: 0.085)

struct VintageChangerView: View {
    @Bindable var player: Player
    let settings: () -> Void
    let resync: () -> Void
    private enum SearchField: Hashable { case library, sets }
    @FocusState private var focusedSearch: SearchField?
    @State private var search = ""
    @AppStorage("cdLibrarySort") private var librarySort: LibrarySort = .album
    @State private var selectedAlbumID: String?
    @State private var showingSets = false
    @State private var setSearch = ""
    @State private var selectedSetID: String?
    @State private var deletingSet: CDSet?
    @AppStorage("shuffleCDSets") private var shuffleSets = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var targeted = false
    @State private var draggedAlbum: Album?
    @State private var draggedDisc: Disc?
    @State private var libraryTargeted = false
    @State private var dragPoint: CGPoint = .zero
    @State private var dragSpace = AlbumDragSpace()
    @State private var operation: String?
    @State private var movingAlbum: Album?
    @State private var ejecting = false
    @State private var motion = false
    private var motionAnimation: Animation { .easeInOut(duration: reduceMotion ? 0.15 : 0.7) }
    private func selectAlbum(_ album: Album) {
        guard operation == nil, !player.draggingAlbum else { return }
        focusedSearch = nil
        selectedAlbumID = album.id
    }
    private func loadAlbum(_ album: Album, play: Bool = false) {
        guard operation == nil, !player.draggingAlbum, !player.staleQueue, play || !player.isLoaded(album) else { return }
        operation = (play ? "PLAYING · " : "LOADING · ") + album.title
        Task { @MainActor in
            // A drop must not be lost just because a status request was in flight.
            player.draggingAlbum = true
            defer { player.draggingAlbum = false; operation = nil }
            while player.busy {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
            let wasLoaded = player.isLoaded(album)
            let success = await player.load(album, play: play)
            if success && !wasLoaded { await animateDisc(album, eject: false) }
            operation = nil
        }
    }
    private func ejectDisc(_ disc: Disc) {
        guard operation == nil, !player.staleQueue else { return }
        operation = "EJECTING · " + disc.album
        let album = albumForDisc(disc)
        Task { @MainActor in
            player.draggingAlbum = true
            defer { player.draggingAlbum = false; operation = nil }
            while player.busy {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
            guard !player.staleQueue, player.discs.contains(where: { $0.id == disc.id }) else { return }
            let success = await player.action("/discs/\(disc.id)", method: "DELETE")
            if success { await animateDisc(album, eject: true) }
            operation = nil
        }
    }
    private func ejectAllDiscs() {
        guard operation == nil, !player.busy, !player.draggingAlbum, !player.staleQueue, !player.discs.isEmpty else { return }
        operation = "EJECTING ALL DISCS"
        Task { @MainActor in
            player.draggingAlbum = true
            defer { player.draggingAlbum = false; operation = nil }
            await player.action("/discs", method: "DELETE", success: "All discs ejected")
        }
    }
    @MainActor private func animateDisc(_ album: Album, eject: Bool) async {
        ejecting = eject
        motion = false
        movingAlbum = album
        try? await Task.sleep(for: .milliseconds(60))
        withAnimation(motionAnimation) { motion = true }
        try? await Task.sleep(for: .milliseconds(reduceMotion ? 200 : 800))
        movingAlbum = nil
        motion = false
    }
    private var albums: [Album] {
        player.albums.filter { search.isEmpty || ($0.title + " " + ($0.artist ?? "")).localizedCaseInsensitiveContains(search) }.sorted(by: librarySort.precedes)
    }
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > 650
            VStack(spacing: 0) {
                header
                if wide {
                    HStack(alignment: .top, spacing: 22) {
                        library.frame(maxWidth: .infinity)
                        machine.frame(width: min(460, geometry.size.width * 0.43))
                    }.padding(24)
                } else {
                    ScrollView {
                        VStack(spacing: 24) {
                            machine.frame(height: 760)
                            library.frame(height: 650)
                        }.padding(20)
                    }
                }
            }
            .background(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.075)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(alignment: .topLeading) {
                if let album = draggedAlbum {
                    JewelCase(album: album).frame(width: 145)
                        .rotationEffect(.degrees(-5)).shadow(color: .black.opacity(0.7), radius: 15, y: 10)
                        .position(dragPoint).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .background { AlbumCoordinateSurface(space: dragSpace, region: .canvas).allowsHitTesting(false) }
            .onDisappear { clearDrag(); selectedAlbumID = nil }
            .onChange(of: search) { _, _ in selectedAlbumID = nil }
            .onChange(of: showingSets) { _, _ in focusedSearch = nil }
            .scrollDismissesKeyboard(.interactively)
        }
    }
    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("STEREO").font(.system(size: 24, weight: .black, design: .rounded)).tracking(5)
                Text(player.demoMode ? "FICTIONAL COMPACT DISC COLLECTION" : "GRAMMY'S COMPACT DISC COLLECTION")
                    .font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(2)
            }
            Spacer()
            HStack(spacing: 8) {
                Circle().fill(player.connected ? amber : .gray).frame(width: 6, height: 6)
                    .shadow(color: player.connected ? amber.opacity(0.7) : .clear, radius: 5)
                Text(player.demoMode ? "DEMO · FICTIONAL LIBRARY" : (player.connected ? "GARAGE CONNECTED" : "GARAGE OFFLINE"))
                    .font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1)
            }
            Button(action: settings) { Image(systemName: "gearshape").frame(width: 44, height: 44) }
                .buttonStyle(HardwareButtonStyle()).accessibilityLabel("Connection settings")
        }.foregroundStyle(Color(white: 0.78)).padding(.horizontal, 24).padding(.vertical, 12)
            .background(Color(white: 0.12)).overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
    }
    private var dismissSearchKeyboard: some View {
        Button("Done") { focusedSearch = nil }
            .font(.subheadline.weight(.semibold)).foregroundStyle(amber)
            .frame(minWidth: 44, minHeight: 44).fixedSize()
            .accessibilityLabel("Done searching, hide keyboard")
    }
    private var library: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                collectionTab("CD Library", icon: "square.stack", sets: false)
                collectionTab("CD Sets", icon: "opticaldisc", sets: true)
            }
            if showingSets {
                setCollection
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("CD Library").font(.system(size: 27, weight: .semibold, design: .serif))
                    Spacer()
                    Text("\(albums.count) \(albums.count == 1 ? "ALBUM" : "ALBUMS")").font(.system(size: 10, design: .monospaced)).tracking(1).foregroundStyle(.white.opacity(0.45))
                    Button { Task { await player.refresh(library: true) } } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }
                        .buttonStyle(HardwareButtonStyle()).disabled(player.busy).accessibilityLabel("Refresh library")
                }
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.4))
                    TextField("Find an album or artist", text: $search).font(.subheadline).autocorrectionDisabled()
                        .focused($focusedSearch, equals: .library)
                        .submitLabel(.done).onSubmit { focusedSearch = nil }
                    if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Clear search") }
                    if focusedSearch == .library { dismissSearchKeyboard }
                }.padding(13).background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.08)))
                HStack {
                    LibrarySortSelector(selection: $librarySort).disabled(player.draggingAlbum)
                    Spacer()
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 18)], spacing: 22) {
                        ForEach(albums) { album in
                            VStack(spacing: 10) {
                                Group {
                                    if player.isLoaded(album) {
                                        JewelCase(album: album).accessibilityElement(children: .ignore).saturation(0).opacity(0.35)
                                            .overlay(alignment: .topTrailing) {
                                                Label("LOADED", systemImage: "checkmark.circle.fill")
                                                    .font(.system(size: 9, weight: .bold)).padding(7).background(.black.opacity(0.85), in: Capsule())
                                            }
                                            .contentShape(Rectangle())
                                            .onTapGesture { selectAlbum(album) }
                                            .accessibilityLabel("\(album.title), already loaded")
                                    } else {
                                        JewelCase(album: album)
                                            .contentShape(Rectangle())
                                            .accessibilityElement(children: .ignore)
                                            .opacity(draggedAlbum?.id == album.id ? 0.25 : 1)
                                            .overlay {
                                                AlbumPanSurface(space: dragSpace, tapped: { selectAlbum(album) }) { point, overPlayer, ended, cancelled in
                                                    handleDrag(album, point: point, overPlayer: overPlayer, ended: ended, cancelled: cancelled)
                                                }.accessibilityHidden(true)
                                            }
                                            .accessibilityLabel("\(album.title) by \(album.artist ?? "unknown artist"). Drag to the player to load.")
                                            .accessibilityAction(named: "Load into magazine") { loadAlbum(album) }
                                    }
                                }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAddTraits(selectedAlbumID == album.id ? .isSelected : [])
                                .accessibilityHint("Select this CD to show the Play now button.")
                                .accessibilityAction { selectAlbum(album) }
                                .overlay {
                                    RoundedRectangle(cornerRadius: 5)
                                        .stroke(selectedAlbumID == album.id ? amber : .clear, lineWidth: 2)
                                        .allowsHitTesting(false)
                                }
                                .animation(.easeInOut(duration: 0.25), value: player.isLoaded(album))
                                if selectedAlbumID == album.id {
                                    Button { loadAlbum(album, play: true) } label: {
                                        Label("Play now", systemImage: "play.fill")
                                            .font(.system(size: 12, weight: .semibold))
                                            .frame(maxWidth: .infinity).frame(minHeight: 44)
                                    }.buttonStyle(HardwareButtonStyle())
                                        .disabled(operation != nil || player.busy || player.draggingAlbum || player.staleQueue)
                                        .accessibilityLabel("Play now, \(album.title)")
                                }
                            }

                        }
                    }.padding(3)
                    if albums.isEmpty {
                        ContentUnavailableView(search.isEmpty ? "Your collection awaits" : "No matching albums", systemImage: "opticaldisc", description: Text(search.isEmpty ? "Use refresh to connect to your library." : "Try another title or artist."))
                    }
                }
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { focusedSearch = nil })
                Text(draggedDisc != nil ? "RELEASE OVER THE COLLECTION TO UNLOAD" : "TAP TO SELECT · DRAG TO LOAD OR UNLOAD").font(.system(size: 9, design: .monospaced)).tracking(1.3).foregroundStyle(.white.opacity(0.35))
            }
        }
        .background { AlbumCoordinateSurface(space: dragSpace, region: .library).allowsHitTesting(false) }
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(libraryTargeted ? amber : .clear, lineWidth: 3))
        .overlay(alignment: .top) {
            if libraryTargeted {
                Text("RELEASE TO UNLOAD DISC")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .padding(12).frame(maxWidth: .infinity).background(amber).foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 5)).padding(8).allowsHitTesting(false)
            }
        }
    }
    private func collectionTab(_ title: String, icon: String, sets: Bool) -> some View {
        Button {
            showingSets = sets
            selectedAlbumID = nil
            selectedSetID = nil
        } label: {
            Label(title, systemImage: icon).font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity).frame(minHeight: 44)
        }.buttonStyle(HardwareButtonStyle())
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(showingSets == sets ? amber : .clear, lineWidth: 2))
            .accessibilityAddTraits(showingSets == sets ? .isSelected : [])
            .disabled(player.draggingAlbum)
    }
    private var filteredSets: [CDSet] {
        player.cdSets.filter { setSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(setSearch) }
    }
    private func setCover(_ cdSet: CDSet) -> Album {
        let artwork = cdSet.albums.compactMap { entry in
            player.albums.first {
                $0.title.compare(entry.title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame &&
                ($0.artist ?? "").compare(entry.artist ?? "", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame &&
                $0.album_art_uri != nil
            }?.album_art_uri
        }.first
        return Album(title: cdSet.name, artist: "\(cdSet.albums.count) CDs", album_art_uri: artwork, uri: nil)
    }
    private var setCollection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Saved CD Sets").font(.system(size: 27, weight: .semibold, design: .serif))
                Spacer()
                Button { Task { await player.refresh(library: true) } } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                }.buttonStyle(HardwareButtonStyle()).disabled(player.busy || player.draggingAlbum)
                    .accessibilityLabel("Refresh CD Sets")
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.4))
                TextField("Find a CD set", text: $setSearch).font(.subheadline).autocorrectionDisabled()
                    .focused($focusedSearch, equals: .sets)
                    .submitLabel(.done).onSubmit { focusedSearch = nil }
                if !setSearch.isEmpty {
                    Button { setSearch = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Clear set search")
                }
                if focusedSearch == .sets { dismissSearchKeyboard }
            }.padding(13).background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 5))
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 18)], spacing: 22) {
                    ForEach(filteredSets) { cdSet in setCard(cdSet) }
                }.padding(3)
                if filteredSets.isEmpty {
                    ContentUnavailableView(!player.setsAvailable ? "CD Sets unavailable" : (setSearch.isEmpty ? "No saved CD sets" : "No matching sets"), systemImage: "opticaldisc",
                        description: Text(!player.setsAvailable ? "Update the NAS backend to enable CD Sets." : (setSearch.isEmpty ? "Load some CDs, then choose Save CD Set on the player." : "Try another set name.")))
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { focusedSearch = nil })
            Text("SELECT A SET, THEN PLAY NOW").font(.system(size: 9, design: .monospaced)).tracking(1.3).foregroundStyle(.white.opacity(0.35))
        }
        .onChange(of: setSearch) { _, _ in selectedSetID = nil }
        .confirmationDialog("Delete \(deletingSet?.name ?? "set")?", isPresented: Binding(get: { deletingSet != nil }, set: { if !$0 { deletingSet = nil } }), titleVisibility: .visible) {
            Button("Delete this set", role: .destructive) {
                if let cdSet = deletingSet { Task { await player.deleteSet(cdSet) } }
                deletingSet = nil
            }
        } message: { Text("The loaded CDs and current playback will stay as they are.") }
    }
    private func setCard(_ cdSet: CDSet) -> some View {
        VStack(spacing: 10) {
            Button { focusedSearch = nil; selectedSetID = cdSet.id } label: { JewelCase(album: setCover(cdSet)) }
                .buttonStyle(.plain)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(selectedSetID == cdSet.id ? amber : .clear, lineWidth: 2))
                .accessibilityLabel("\(cdSet.name), \(cdSet.albums.count) CDs")
                .accessibilityHint("Select to show Play now and Delete this set.")
                .accessibilityAddTraits(selectedSetID == cdSet.id ? .isSelected : [])
            if selectedSetID == cdSet.id {
                Text("Replaces all CDs in the player.").font(.caption).foregroundStyle(.secondary)
                Button { Task { await player.playSet(cdSet, shuffle: shuffleSets) } } label: {
                    Label("Play now", systemImage: "play.fill").font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity).frame(minHeight: 44)
                }.buttonStyle(HardwareButtonStyle()).accessibilityLabel("Play now, \(cdSet.name)")
                Button(role: .destructive) { deletingSet = cdSet } label: {
                    Label("Delete this set", systemImage: "trash").font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity).frame(minHeight: 44)
                }.buttonStyle(HardwareButtonStyle()).accessibilityLabel("Delete this set, \(cdSet.name)")
            }
        }.disabled(operation != nil || player.busy || player.draggingAlbum || !player.setsAvailable)
    }
    private var machine: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("CD CHANGER").font(.system(size: 14, weight: .heavy)).tracking(3)
                        Spacer()
                        Text("MULTI DISC").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1)
                    }.foregroundStyle(Color(white: 0.7))
                    display
                    CDSetControls(player: player, showSetBrowser: false).tint(amber)
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("DISC MAGAZINE").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2)
                            Text("\(player.discs.count) LOADED").font(.system(size: 9, design: .monospaced)).foregroundStyle(amber)
                        }
                        Spacer()
                        Button(action: ejectAllDiscs) {
                            HStack(spacing: 6) {
                                Text("EJECT ALL").font(.system(size: 9, weight: .bold, design: .monospaced))
                                Image(systemName: "eject.fill").font(.caption).frame(width: 44)
                            }.padding(.leading, 10).frame(minHeight: 44)
                        }.buttonStyle(HardwareButtonStyle())
                            .disabled(player.discs.isEmpty || player.busy || player.draggingAlbum || player.staleQueue)
                            .accessibilityLabel("Eject all discs")
                            .padding(.trailing, 10)
                    }.foregroundStyle(.white.opacity(0.5))
                    if player.staleQueue {
                        Text("The queue changed in Sonos. Reset the magazine assignments to continue.").font(.footnote).foregroundStyle(amber)
                        Button("Reset disc tracking", action: resync).buttonStyle(HardwareButtonStyle())
                    }
                    ScrollViewReader { magazine in
                     ScrollView {
                      VStack(spacing: 5) {
                        ForEach(Array(player.discs.enumerated()), id: \.element.id) { index, disc in
                            discSlot(index + 1, disc: disc).id(disc.id)
                                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
                        }
                        ForEach(player.discs.count..<max(6, player.discs.count), id: \.self) { index in
                            discSlot(index + 1, disc: nil)
                        }
                    }.animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: player.discs.map(\.id))
                    }.onChange(of: player.discs.map(\.id)) { old, new in
                        if new.count > old.count, let last = new.last {
                            withAnimation(reduceMotion ? nil : .easeInOut) { magazine.scrollTo(last, anchor: .bottom) }
                        }
                    }
                    }.frame(minHeight: 100)
                    VintageTransport(player: player)
                }.padding(18)
            }.background(Color(white: 0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.08), lineWidth: 1))
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { focusedSearch = nil })
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(targeted ? amber : .clear, lineWidth: 3))
        .overlay(alignment: .top) {
            if targeted || operation != nil {
                Text(operation ?? "RELEASE TO LOAD INTO MAGAZINE")
                    .font(.system(size: 11, weight: .bold, design: .monospaced)).lineLimit(2)
                    .padding(12).frame(maxWidth: .infinity).background(amber).foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 5)).padding(8)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if let album = movingAlbum {
                VStack(spacing: 14) {
                    LoadingDisc(album: album)
                        .frame(width: 160, height: 160)
                        .scaleEffect(reduceMotion ? 1 : (ejecting ? (motion ? 1.05 : 0.35) : (motion ? 0.3 : 1)))
                        .offset(y: reduceMotion ? 0 : (ejecting ? (motion ? -70 : 30) : (motion ? 40 : -80)))
                        .opacity(reduceMotion ? (motion ? 0 : 1) : (motion ? (ejecting ? 0 : 0.1) : 1))
                    Text(ejecting ? "DISC EJECTED" : "DISC LOADED").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(amber)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black.opacity(0.45))
                    .clipShape(RoundedRectangle(cornerRadius: 10)).allowsHitTesting(false)
            }
        }
        .disabled(operation != nil)
        .background {
            AlbumCoordinateSurface(space: dragSpace, region: .player).allowsHitTesting(false)
        }
    }
    private func handleDrag(_ album: Album, point: CGPoint, overPlayer: Bool, ended: Bool, cancelled: Bool) {
        if ended {
            guard draggedAlbum?.id == album.id else { return }
            let accepted = !cancelled && overPlayer
            clearDrag()
            if accepted { loadAlbum(album) }
            return
        }
        guard operation == nil, !player.staleQueue, !player.isLoaded(album) else { return }
        selectedAlbumID = nil
        draggedAlbum = album
        player.draggingAlbum = true
        dragPoint = point
        targeted = overPlayer
    }

    private func albumForDisc(_ disc: Disc) -> Album {
        player.albums.first { $0.title == disc.album && $0.artist == disc.artist }
            ?? Album(title: disc.album, artist: disc.artist, album_art_uri: nil, uri: nil)
    }
    private func clearDrag() {
        draggedAlbum = nil
        draggedDisc = nil
        targeted = false
        libraryTargeted = false
        player.draggingAlbum = false
    }
    private func handleDiscDrag(_ disc: Disc, point: CGPoint, overLibrary: Bool, ended: Bool, cancelled: Bool) {
        if ended {
            guard draggedDisc?.id == disc.id else { return }
            let accepted = !cancelled && overLibrary
            clearDrag()
            if accepted { ejectDisc(disc) }
            return
        }
        guard operation == nil, !player.staleQueue, player.discs.contains(where: { $0.id == disc.id }) else { return }
        draggedDisc = disc
        draggedAlbum = albumForDisc(disc)
        player.draggingAlbum = true
        dragPoint = point
        libraryTargeted = overLibrary
    }

    private var displayState: String {
        guard player.connected else { return "OFFLINE" }
        switch player.status?.transport["current_transport_state"] {
        case "PLAYING": return "▶ PLAY"
        case "PAUSED_PLAYBACK": return "Ⅱ PAUSE"
        case "TRANSITIONING": return "READING…"
        default: return "STANDBY"
        }
    }
    private var display: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(displayState)
                Spacer()
                Text(player.currentDisc.flatMap { id in player.discs.firstIndex { $0.id == id }.map { String(format: "DISC %02d", $0 + 1) } } ?? "DISC —")
            }.font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(2)
            Text(player.status?.track["title"].flatMap { $0.isEmpty ? nil : $0 } ?? "READY TO PLAY")
                .font(.system(size: 23, weight: .medium, design: .monospaced)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            Text(player.status?.track["artist"] ?? "Select a disc from the collection").font(.system(size: 12, design: .monospaced)).lineLimit(1).opacity(0.65)
            HStack(alignment: .lastTextBaseline) {
                Text(player.status?.track["position"] ?? "0:00:00").font(.system(size: 28, weight: .light, design: .monospaced)).monospacedDigit()
                Spacer()
                Text("ELAPSED").font(.system(size: 8, design: .monospaced)).tracking(2).opacity(0.5)
            }
        }.foregroundStyle(amber).padding(18)
            .background(Color(red: 0.055, green: 0.045, blue: 0.025))
            .overlay { ScanLines().allowsHitTesting(false) }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.black, lineWidth: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.08), lineWidth: 1))
    }
    private func discSlot(_ number: Int, disc: Disc?) -> some View {
        HStack(spacing: 12) {
            Text(String(format: "%02d", number)).font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(disc?.id == player.currentDisc && disc != nil ? amber : .white.opacity(0.3)).frame(width: 25)
            if let disc {
                Button { Task { await player.action("/discs/\(disc.id)/play") } } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(disc.album).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Text(disc.artist ?? "Unknown artist").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .opacity(draggedDisc?.id == disc.id ? 0.25 : 1)
                    .overlay {
                        AlbumPanSurface(space: dragSpace, destination: .library, tapped: {
                            guard operation == nil, !player.busy, !player.staleQueue else { return }
                            Task { await player.action("/discs/\(disc.id)/play") }
                        }) { point, overLibrary, ended, cancelled in
                            handleDiscDrag(disc, point: point, overLibrary: overLibrary, ended: ended, cancelled: cancelled)
                        }.accessibilityHidden(true)
                    }
                    .accessibilityLabel("Play disc \(number), \(disc.album)")
                    .accessibilityHint("Drag sideways to the collection to unload.")
                    .accessibilityAction(named: "Unload to collection") { ejectDisc(disc) }
                Button { Task { await player.action("/discs/\(disc.id)/play") } } label: {
                    Image(systemName: "play.fill").font(.caption).foregroundStyle(amber)
                        .frame(width: 44, height: 44)
                }.buttonStyle(HardwareButtonStyle()).accessibilityLabel("Play disc \(number), \(disc.album)")
                Button { ejectDisc(disc) } label: {
                    Image(systemName: "eject.fill").font(.caption).frame(width: 44, height: 44)
                }.buttonStyle(HardwareButtonStyle()).accessibilityLabel("Eject disc \(number), \(disc.album)")
            } else {
                Text("EMPTY").font(.system(size: 9, design: .monospaced)).tracking(3).foregroundStyle(.white.opacity(0.15))
                Spacer()
                Rectangle().fill(.black.opacity(0.5)).frame(width: 35, height: 2)
            }
        }.frame(minHeight: 47).padding(.horizontal, 10).padding(.vertical, 3)
            .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
            .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.04)).frame(height: 1) }
            .disabled(player.busy || player.staleQueue)
    }
}

private struct VintageTransport: View {
    @Bindable var player: Player
    @State private var volume = 0.0
    private var transport: String { player.status?.transport["current_transport_state"] ?? "" }
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                transportButton("Previous disc", icon: "backward.end.fill", path: "/discs/previous", disabled: player.discs.isEmpty || player.staleQueue)
                transportButton(transport == "PLAYING" ? "Pause" : "Play", icon: transport == "PLAYING" ? "pause.fill" : "play.fill", path: transport == "PLAYING" ? "/pause" : "/play", disabled: !["PLAYING", "PAUSED_PLAYBACK", "STOPPED"].contains(transport) || (player.status?.track["uri"] ?? "").isEmpty)
                transportButton("Next disc", icon: "forward.end.fill", path: "/discs/next", disabled: player.discs.isEmpty || player.staleQueue)
            }
            HStack(spacing: 12) {
                transportButton("Previous track", icon: "backward.fill", path: "/tracks/previous", disabled: (player.status?.track["uri"] ?? "").isEmpty)
                transportButton("Next track", icon: "forward.fill", path: "/tracks/next", disabled: (player.status?.track["uri"] ?? "").isEmpty)
            }
            HStack(spacing: 16) {
                ZStack {
                    Circle().fill(AngularGradient(colors: [Color(white: 0.4), Color(white: 0.16), Color(white: 0.5), Color(white: 0.2), Color(white: 0.4)], center: .center))
                    Circle().stroke(.black.opacity(0.8), lineWidth: 3)
                    Capsule().fill(amber).frame(width: 3, height: 12).offset(y: -16).rotationEffect(.degrees(-135 + volume * 2.7))
                }.frame(width: 54, height: 54).shadow(color: .black.opacity(0.7), radius: 3, y: 3).accessibilityHidden(true)
                VStack(spacing: 4) {
                    HStack {
                        Text("VOLUME LEVEL").tracking(1.5)
                        Spacer()
                        Text(player.status?.volume == nil ? "—" : "\(Int(volume))\(player.status?.muted == true ? " · MUTED" : "")").foregroundStyle(amber)
                    }.font(.system(size: 9, weight: .medium, design: .monospaced))
                    Slider(value: $volume, in: 0...100, step: 1) { editing in
                        player.editingVolume = editing
                        if !editing {
                            let value = Int(volume)
                            Task {
                                await player.action("/volume", query: [URLQueryItem(name: "level", value: String(value))])
                                volume = Double(player.status?.volume ?? value)
                            }
                        }
                    }.tint(amber).disabled(player.busy || player.status?.volume == nil)
                        .accessibilityLabel("\(player.demoMode ? "Sonos Speaker" : "Garage") volume").accessibilityValue("\(Int(volume)) percent")
                }.foregroundStyle(.white.opacity(0.5))
            }
        }.onAppear { volume = Double(player.status?.volume ?? 0) }
            .onChange(of: player.status?.volume) { _, value in if !player.editingVolume { volume = Double(value ?? 0) } }
            .onDisappear { player.editingVolume = false }
    }
    private func transportButton(_ title: String, icon: String, path: String, disabled: Bool) -> some View {
        Button { Task { await player.action(path) } } label: {
            VStack(spacing: 8) { Image(systemName: icon).font(.title3); Text(title.uppercased()).font(.system(size: 8, weight: .semibold)).tracking(1) }
                .frame(maxWidth: .infinity).frame(height: 48)
        }.buttonStyle(HardwareButtonStyle()).disabled(player.busy || disabled).accessibilityLabel(title)
    }
}

private struct JewelCase: View {
    let album: Album
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .leading) {
                GeometryReader { geo in
                    AsyncImage(url: album.album_art_uri.flatMap { URL(string: $0, relativeTo: URL(string: "http://192.168.1.85:1400")) }) { image in image.resizable().scaledToFill() } placeholder: {
                        ZStack {
                            LinearGradient(colors: [Color(white: 0.3), Color(white: 0.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
                            Image(systemName: "opticaldisc").font(.system(size: 55, weight: .ultraLight)).foregroundStyle(.white.opacity(0.3))
                        }
                    }.frame(width: geo.size.width, height: geo.size.height).clipped()
                }
                Rectangle().fill(.black.opacity(0.65)).frame(width: 9)
                Rectangle().fill(.white.opacity(0.13)).frame(width: 2).padding(.leading, 10)
                LinearGradient(colors: [.white.opacity(0.18), .clear, .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
            }.aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.25)))
                .shadow(color: .black.opacity(0.65), radius: 4, x: 3, y: 5)
            Text(album.title).font(.system(size: 12, weight: .semibold)).lineLimit(2).frame(height: 32, alignment: .topLeading)
            Text(album.artist ?? "Unknown artist").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
        }.foregroundStyle(.white.opacity(0.85))
    }
}
private struct HardwareButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(Color(white: 0.8))
            .background(LinearGradient(colors: configuration.isPressed ? [Color(white: 0.12), Color(white: 0.18)] : [Color(white: 0.3), Color(white: 0.18)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.black.opacity(0.8)))
            .shadow(color: .black.opacity(0.6), radius: configuration.isPressed ? 0 : 2, y: configuration.isPressed ? 0 : 3)
            .opacity(enabled ? 1 : 0.35).offset(y: configuration.isPressed ? 1 : 0)
    }
}
private struct ScanLines: View {
    var body: some View {
        Canvas { context, size in
            for y in stride(from: 0.0, to: size.height, by: 3) {
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(0.15)))
            }
        }.accessibilityHidden(true)
    }
}

private struct LoadingDisc: View {
    let album: Album
    var body: some View {
        ZStack {
            Circle().fill(AngularGradient(colors: [.gray, .white, .gray, Color(red: 0.65, green: 0.75, blue: 0.85), .white, .gray], center: .center))
            Circle().stroke(.white.opacity(0.4), lineWidth: 1).padding(8)
            Circle().fill(amber.opacity(0.8)).padding(35)
            Text(album.title).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.black).multilineTextAlignment(.center).lineLimit(2).padding(48).offset(y: -22)
            Circle().fill(Color(white: 0.1)).frame(width: 25, height: 25).overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 4))
        }.shadow(color: .black.opacity(0.8), radius: 10, y: 8).accessibilityHidden(true)
    }
}

// Use live UIKit views for both the preview and target. SwiftUI global coordinates
// need not match UIWindow coordinates in an iPad's safe areas or resized windows.
private enum AlbumDragRegion { case canvas, player, library }

private final class AlbumDragSpace {
    weak var canvas: UIView?
    weak var player: UIView?
    weak var library: UIView?

    func sample(_ recognizer: UIPanGestureRecognizer, destination: AlbumDragRegion) -> (point: CGPoint, overTarget: Bool) {
        let point = recognizer.location(in: canvas)
        guard let sourceWindow = recognizer.view?.window,
              let target = destination == .library ? library : player, target.window === sourceWindow else {
            return (point, false)
        }
        return (point, target.bounds.contains(recognizer.location(in: target)))
    }
}

private struct AlbumCoordinateSurface: UIViewRepresentable {
    let space: AlbumDragSpace
    let region: AlbumDragRegion
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        register(view)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) { register(uiView) }
    private func register(_ view: UIView) {
        switch region {
        case .canvas: space.canvas = view
        case .player: space.player = view
        case .library: space.library = view
        }
    }
}

// A horizontal recognizer yields vertical gestures to the collection's scroll view.
// Keep scrolling configuration stable while the recognizer owns the touch.
private struct AlbumPanSurface: UIViewRepresentable {
    let space: AlbumDragSpace
    var destination: AlbumDragRegion = .player
    var tapped: (() -> Void)? = nil
    var changed: (CGPoint, Bool, Bool, Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(space: space, destination: destination, tapped: tapped, changed: changed) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.delegate = context.coordinator
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        if tapped != nil {
            let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap))
            tap.require(toFail: pan)
            view.addGestureRecognizer(tap)
        }
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.changed = changed
        context.coordinator.tapped = tapped
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let space: AlbumDragSpace
        let destination: AlbumDragRegion
        var tapped: (() -> Void)?
        var changed: (CGPoint, Bool, Bool, Bool) -> Void
        init(space: AlbumDragSpace, destination: AlbumDragRegion, tapped: (() -> Void)?, changed: @escaping (CGPoint, Bool, Bool, Bool) -> Void) {
            self.space = space
            self.destination = destination
            self.tapped = tapped
            self.changed = changed
        }
        @objc func tap() { tapped?() }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }
        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            let sample = space.sample(recognizer, destination: destination)
            switch recognizer.state {
            case .began, .changed: changed(sample.point, sample.overTarget, false, false)
            case .ended: changed(sample.point, sample.overTarget, true, false)
            case .cancelled, .failed: changed(sample.point, sample.overTarget, true, true)
            default: break
            }
        }
    }
}
