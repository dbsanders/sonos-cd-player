import SwiftUI
import UIKit

private let amber = Color(red: 1, green: 0.66, blue: 0.25)
private let ink = Color(red: 0.08, green: 0.085, blue: 0.085)

struct VintageChangerView: View {
    @Bindable var player: Player
    let settings: () -> Void
    let resync: () -> Void
    @State private var search = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var targeted = false
    @State private var draggedAlbum: Album?
    @State private var dragPoint: CGPoint = .zero
    @State private var dragSpace = AlbumDragSpace()
    @State private var operation: String?
    @State private var movingAlbum: Album?
    @State private var ejecting = false
    @State private var motion = false
    private var motionAnimation: Animation { .easeInOut(duration: reduceMotion ? 0.15 : 0.7) }
    private func loadAlbum(_ album: Album) {
        guard operation == nil, !player.staleQueue, !player.isLoaded(album) else { return }
        operation = "LOADING · " + album.title
        Task { @MainActor in
            // A drop must not be lost just because a status request was in flight.
            player.draggingAlbum = true
            defer { player.draggingAlbum = false; operation = nil }
            while player.busy {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
            let success = await player.load(album)
            if success { await animateDisc(album, eject: false) }
            operation = nil
        }
    }
    private func ejectDisc(_ disc: Disc) {
        guard operation == nil, !player.busy else { return }
        operation = "EJECTING · " + disc.album
        let album = player.albums.first { $0.title == disc.album && $0.artist == disc.artist }
            ?? Album(title: disc.album, artist: disc.artist, album_art_uri: nil, uri: nil)
        Task { @MainActor in
            let success = await player.action("/discs/\(disc.id)", method: "DELETE")
            if success { await animateDisc(album, eject: true) }
            operation = nil
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
        player.albums.filter { search.isEmpty || ($0.title + " " + ($0.artist ?? "")).localizedCaseInsensitiveContains(search) }
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
                            machine.frame(height: 810)
                            library.frame(height: 650)
                        }.padding(20)
                    }
                }
                HStack {
                    Text("COMPACT DISC DIGITAL AUDIO")
                    Spacer()
                    Text("GARAGE  /  PERSONAL MUSIC SYSTEM")
                }.font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(2)
                    .foregroundStyle(.white.opacity(0.3)).padding(.horizontal, 30).padding(.bottom, 14)
            }
            .background(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.075)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(alignment: .topLeading) {
                if let album = draggedAlbum {
                    JewelCase(album: album).frame(width: 145)
                        .rotationEffect(.degrees(-5)).shadow(color: .black.opacity(0.7), radius: 15, y: 10)
                        .position(dragPoint).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .background { AlbumCoordinateSurface(space: dragSpace, isPlayer: false).allowsHitTesting(false) }
            .onDisappear { draggedAlbum = nil; targeted = false; player.draggingAlbum = false }
        }
    }
    private var header: some View {
        HStack(spacing: 16) {
            Screw()
            VStack(alignment: .leading, spacing: 3) {
                Text("STEREO").font(.system(size: 24, weight: .black, design: .rounded)).tracking(5)
                Text("THE COMPACT DISC COLLECTION").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(2)
            }
            Spacer()
            HStack(spacing: 8) {
                Circle().fill(player.connected ? amber : .gray).frame(width: 6, height: 6)
                    .shadow(color: player.connected ? amber.opacity(0.7) : .clear, radius: 5)
                Text(player.connected ? "GARAGE CONNECTED" : "GARAGE OFFLINE").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1)
            }
            Button(action: settings) { Image(systemName: "gearshape").frame(width: 44, height: 44) }
                .buttonStyle(HardwareButtonStyle()).accessibilityLabel("Connection settings")
            Screw()
        }.foregroundStyle(Color(white: 0.78)).padding(.horizontal, 24).padding(.vertical, 18)
            .background(MetalSurface()).overlay(alignment: .bottom) { Rectangle().fill(.black.opacity(0.6)).frame(height: 2) }
    }
    private var library: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("The collection").font(.system(size: 27, weight: .semibold, design: .serif))
                Spacer()
                Text("\(albums.count) \(albums.count == 1 ? "ALBUM" : "ALBUMS")").font(.system(size: 10, design: .monospaced)).tracking(1).foregroundStyle(.white.opacity(0.45))
                Button { Task { await player.refresh(library: true) } } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }
                    .buttonStyle(HardwareButtonStyle()).disabled(player.busy).accessibilityLabel("Refresh library")
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.4))
                TextField("Find an album or artist", text: $search).font(.subheadline).autocorrectionDisabled()
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Clear search") }
            }.padding(13).background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.08)))
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 18)], spacing: 22) {
                    ForEach(albums) { album in
                        Group {
                            if player.isLoaded(album) {
                                JewelCase(album: album).accessibilityElement(children: .ignore).saturation(0).opacity(0.35)
                                    .overlay(alignment: .topTrailing) {
                                        Label("LOADED", systemImage: "checkmark.circle.fill")
                                            .font(.system(size: 9, weight: .bold)).padding(7).background(.black.opacity(0.85), in: Capsule())
                                    }
                                    .accessibilityLabel("\(album.title), already loaded")
                            } else {
                                JewelCase(album: album)
                                    .contentShape(Rectangle())
                                    .accessibilityElement(children: .ignore)
                                    .opacity(draggedAlbum?.id == album.id ? 0.25 : 1)
                                    .overlay {
                                        AlbumPanSurface(space: dragSpace) { point, overPlayer, ended, cancelled in
                                            handleDrag(album, point: point, overPlayer: overPlayer, ended: ended, cancelled: cancelled)
                                        }.accessibilityHidden(true)
                                    }
                                    .accessibilityLabel("\(album.title) by \(album.artist ?? "unknown artist"). Drag to the player to load.")
                                    .accessibilityAction(named: "Load into magazine") { loadAlbum(album) }
                            }
                        }.animation(.easeInOut(duration: 0.25), value: player.isLoaded(album))

                    }
                }.padding(3)
                if albums.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "Your collection awaits" : "No matching albums", systemImage: "opticaldisc", description: Text(search.isEmpty ? "Use refresh to connect to your library." : "Try another title or artist."))
                }
            }
            Text("SLIDE A CASE SIDEWAYS, THEN RELEASE OVER THE PLAYER").font(.system(size: 9, design: .monospaced)).tracking(1.3).foregroundStyle(.white.opacity(0.35))
        }
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
                    HStack {
                        Text("DISC MAGAZINE").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2)
                        Spacer()
                        Text("\(player.discs.count) LOADED").font(.system(size: 9, design: .monospaced)).foregroundStyle(amber)
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
                }.padding(22)
                HStack {
                    Screw(); Spacer()
                    HStack(spacing: 4) { ForEach(0..<18, id: \.self) { _ in Capsule().fill(.black.opacity(0.65)).frame(width: 3, height: 13) } }
                    Spacer(); Screw()
                }.padding(.horizontal, 16).padding(.bottom, 14)
            }.background(MetalSurface())
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(LinearGradient(colors: [.white.opacity(0.24), .black], startPoint: .top, endPoint: .bottom), lineWidth: 1))
                .shadow(color: .black.opacity(0.6), radius: 12, x: 5, y: 12)
                .padding(.bottom, 15)
        }
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
            AlbumCoordinateSurface(space: dragSpace, isPlayer: true).allowsHitTesting(false)
        }
    }
    private func handleDrag(_ album: Album, point: CGPoint, overPlayer: Bool, ended: Bool, cancelled: Bool) {
        if ended {
            guard draggedAlbum?.id == album.id else { return }
            let accepted = !cancelled && overPlayer
            draggedAlbum = nil
            targeted = false
            player.draggingAlbum = false
            if accepted { loadAlbum(album) }
            return
        }
        guard operation == nil, !player.staleQueue, !player.isLoaded(album) else { return }
        draggedAlbum = album
        player.draggingAlbum = true
        dragPoint = point
        targeted = overPlayer
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
                        Image(systemName: disc.id == player.currentDisc ? "speaker.wave.2.fill" : "play.fill").font(.caption).foregroundStyle(amber)
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Play disc \(number), \(disc.album)")
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
                transportButton(transport == "PLAYING" ? "Pause" : "Resume", icon: transport == "PLAYING" ? "pause.fill" : "play.fill", path: transport == "PLAYING" ? "/pause" : "/play", disabled: !["PLAYING", "PAUSED_PLAYBACK", "STOPPED"].contains(transport) || (player.status?.track["uri"] ?? "").isEmpty)
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
                        Text("OUTPUT LEVEL").tracking(1.5)
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
                        .accessibilityLabel("Garage volume").accessibilityValue("\(Int(volume)) percent")
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
private struct Screw: View {
    var body: some View {
        ZStack { Circle().fill(LinearGradient(colors: [Color(white: 0.32), Color(white: 0.1)], startPoint: .topLeading, endPoint: .bottomTrailing)); Capsule().fill(.black.opacity(0.8)).frame(width: 7, height: 1).rotationEffect(.degrees(-35)) }
            .frame(width: 12, height: 12).overlay(Circle().stroke(.black.opacity(0.7))).accessibilityHidden(true)
    }
}
private struct MetalSurface: View {
    var body: some View {
        LinearGradient(colors: [Color(white: 0.27), Color(white: 0.19), Color(white: 0.23)], startPoint: .top, endPoint: .bottom)
            .overlay { Canvas { context, size in
                for y in stride(from: 0.0, to: size.height, by: 2) {
                    var path = Path(); path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(path, with: .color(.white.opacity(0.025)), lineWidth: 0.5)
                }
            }}
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
private final class AlbumDragSpace {
    weak var canvas: UIView?
    weak var player: UIView?

    func sample(_ recognizer: UIPanGestureRecognizer) -> (point: CGPoint, overPlayer: Bool) {
        let point = recognizer.location(in: canvas)
        guard let sourceWindow = recognizer.view?.window,
              let target = player, target.window === sourceWindow else {
            return (point, false)
        }
        return (point, target.bounds.contains(recognizer.location(in: target)))
    }
}

private struct AlbumCoordinateSurface: UIViewRepresentable {
    let space: AlbumDragSpace
    let isPlayer: Bool
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        register(view)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) { register(uiView) }
    private func register(_ view: UIView) {
        if isPlayer { space.player = view } else { space.canvas = view }
    }
}

// A horizontal recognizer yields vertical gestures to the collection's scroll view.
// Keep scrolling configuration stable while the recognizer owns the touch.
private struct AlbumPanSurface: UIViewRepresentable {
    let space: AlbumDragSpace
    var changed: (CGPoint, Bool, Bool, Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(space: space, changed: changed) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.delegate = context.coordinator
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.changed = changed }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let space: AlbumDragSpace
        var changed: (CGPoint, Bool, Bool, Bool) -> Void
        init(space: AlbumDragSpace, changed: @escaping (CGPoint, Bool, Bool, Bool) -> Void) {
            self.space = space
            self.changed = changed
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }
        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            let sample = space.sample(recognizer)
            switch recognizer.state {
            case .began, .changed: changed(sample.point, sample.overPlayer, false, false)
            case .ended: changed(sample.point, sample.overPlayer, true, false)
            case .cancelled, .failed: changed(sample.point, sample.overPlayer, true, true)
            default: break
            }
        }
    }
}
