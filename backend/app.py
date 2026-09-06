from fastapi import FastAPI, HTTPException, Query
import soco

app = FastAPI(title="Sonos CD Player")


def get_speaker():
    return soco.SoCo("192.168.1.85")

@app.get("/")
def root():
    return {"status": "ok"}

@app.get("/speaker")
def speaker_info():
    speaker = get_speaker()

    return {
        "name": speaker.player_name,
        "ip": speaker.ip_address,
        "uid": speaker.uid,
    }

@app.get("/speakers")
def speakers():
    devices = soco.discover(timeout=5)

    if not devices:
        return {"speakers": []}

    return {
        "speakers": [
            {
                "name": speaker.player_name,
                "ip": speaker.ip_address,
                "uid": speaker.uid,
            }
            for speaker in devices
        ]
    }


@app.get("/albums")
def albums():
    speaker = get_speaker()

    library = speaker.music_library
    items = library.get_albums(complete_result=True)

    result = []

    for album in items:
        result.append({
            "title": album.title,
            "artist": getattr(album, "creator", None),
            "album_art_uri": getattr(album, "album_art_uri", None),
            "uri": getattr(album, "resources", [None])[0].uri
                if getattr(album, "resources", None)
                else None,
        })

    return {
        "count": len(result),
        "albums": result,
    }

from changer import Changer
changer = Changer(get_speaker)

@app.post("/play-album")
def play_album(title: str, artist: str | None = None):
    """Append an album as a disc and start it, preserving the existing queue."""
    return changer.load(title, artist, play=True)

@app.get("/discs")
def loaded_discs():
    return changer.listing()

@app.post("/discs/load")
def load_disc(title: str, artist: str | None = None):
    return changer.load(title, artist)

@app.post("/discs/next")
def next_disc():
    return changer.step(1)

@app.post("/discs/previous")
def previous_disc():
    return changer.step(-1)

@app.post("/discs/resync")
def resync_discs():
    """Forget disc mappings after external edits; leave Sonos queue untouched."""
    return changer.resync()

@app.post("/discs/{disc_id}/play")
def play_disc(disc_id: str):
    return changer.play(disc_id)

@app.delete("/discs/{disc_id}")
@app.post("/discs/{disc_id}/eject")
def eject_disc(disc_id: str):
    return changer.eject(disc_id)

@app.get("/status")
def status():
    speaker = get_speaker()

    return {
        "transport": speaker.get_current_transport_info(),
        "track": speaker.get_current_track_info(),
        "queue_size": speaker.queue_size,
        "volume": speaker.volume,
        "muted": speaker.mute,
    }

@app.post("/test-queue")
def test_queue():
    speaker = get_speaker()

    queue = speaker.get_queue()

    return {
        "queue_size": len(queue),
        "items": [
            {
                "title": item.title,
                "creator": getattr(item, "creator", None),
            }
            for item in queue[:10]
        ],
    }

@app.post("/play")
def play():
    speaker = get_speaker()

    return {
        "before": speaker.get_current_transport_info(),
        "result": speaker.play(),
        "after": speaker.get_current_transport_info(),
    }

@app.post("/pause")
def pause():
    speaker = get_speaker()
    speaker.pause()
    return {"transport": speaker.get_current_transport_info()}


def skip_track(direction: str):
    speaker = get_speaker()
    try:
        if direction == "next":
            speaker.next()
        else:
            speaker.previous()
    except soco.exceptions.SoCoUPnPException as exc:
        raise HTTPException(status_code=409, detail="Sonos cannot skip in that direction from the current track.") from exc
    return {"transport": speaker.get_current_transport_info(), "track": speaker.get_current_track_info()}


@app.post("/tracks/next")
def next_track():
    return skip_track("next")


@app.post("/tracks/previous")
def previous_track():
    return skip_track("previous")


@app.get("/volume")
def volume():
    speaker = get_speaker()
    return {"volume": speaker.volume, "muted": speaker.mute}


@app.post("/volume")
def set_volume(level: int = Query(..., ge=0, le=100)):
    speaker = get_speaker()
    speaker.volume = level
    return {"volume": speaker.volume, "muted": speaker.mute}


@app.get("/transport")
def transport():
    speaker = get_speaker()

    return {
        "transport_info": speaker.get_current_transport_info(),
        "track_info": speaker.get_current_track_info(),
    }


@app.get("/album-tracks")
def album_tracks(title: str):
    speaker = get_speaker()
    library = speaker.music_library

    albums = library.get_albums(search_term=title)

    if not albums:
        raise HTTPException(status_code=404, detail="Album not found")

    album = albums[0]
    artist = getattr(album, "creator", None)

    tracks = library.get_tracks_for_album(
        artist=artist,
        album=album.title
    )

    return {
        "album": album.title,
        "artist": artist,
        "count": len(tracks),
        "tracks": [
            {
                "title": getattr(track, "title", None),
                "artist": getattr(track, "creator", None),
                "album": getattr(track, "album", None),
                "uri": (
                    track.resources[0].uri
                    if getattr(track, "resources", None)
                    else None
                )
            }
            for track in tracks
        ]
    }
