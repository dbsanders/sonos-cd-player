import os
from typing import Optional
from urllib.parse import urljoin

from fastapi import FastAPI, HTTPException, Query
import soco
from requests.exceptions import RequestException

app = FastAPI(title="Sonos CD Player")


def get_speaker():
    return soco.SoCo(os.environ.get("SONOS_SPEAKER_IP", "192.168.1.85"))


def get_volume_target(speaker):
    """Use Sonos group volume when grouped, or the speaker for a single-room group."""
    return getattr(speaker, "group", None) or speaker


def album_art_url(speaker, uri):
    """Resolve Sonos's usual relative artwork paths against the configured player."""
    if not uri:
        return None
    return urljoin(f"http://{speaker.ip_address}:1400/", uri)


def prepare_playback(speaker):
    """Join configured rooms only for an explicit music playback request."""
    members = list(dict.fromkeys(ip.strip() for ip in
        os.environ.get("SONOS_GROUP_MEMBERS", "").split(",") if ip.strip()))
    if not members:
        return
    try:
        if not speaker.is_coordinator:
            raise HTTPException(409, "The configured main speaker must lead the Sonos group. "
                                "In Sonos, ungroup it and select it first before adding other rooms.")
        for ip in members:
            if ip == speaker.ip_address:
                continue
            member = soco.SoCo(ip)
            group = member.group
            if group is None:
                raise HTTPException(409, f"Speaker {ip} cannot be grouped independently.")
            if group.coordinator.uid != speaker.uid:
                member.join(speaker)
    except (soco.exceptions.SoCoException, RequestException, OSError) as exc:
        raise HTTPException(503, "Could not group the music speakers. Check that all configured "
                            "rooms are online, then try Play again.") from exc

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
            "album_art_uri": album_art_url(speaker, getattr(album, "album_art_uri", None)),
            "uri": getattr(album, "resources", [None])[0].uri
                if getattr(album, "resources", None)
                else None,
        })

    return {
        "count": len(result),
        "albums": result,
    }

from changer import Changer
changer = Changer(get_speaker, prepare_playback=prepare_playback)

@app.post("/play-album")
def play_album(title: str, artist: Optional[str] = None):
    """Append an album as a disc and start it, preserving the existing queue."""
    return changer.load(title, artist, play=True)

@app.get("/discs")
def loaded_discs():
    return changer.listing()

@app.post("/discs/load")
def load_disc(title: str, artist: Optional[str] = None):
    return changer.load(title, artist)

@app.get("/cd-sets")
def cd_sets():
    return changer.list_sets()

@app.post("/cd-sets")
def save_cd_set(name: str, title: Optional[str] = None, artist: Optional[str] = None):
    return changer.create_set_from_album(name, title, artist) if title is not None else changer.create_set(name)

@app.put("/cd-sets/{set_id}")
def overwrite_cd_set(set_id: str):
    return changer.overwrite_set(set_id)

@app.post("/cd-sets/{set_id}/albums")
def add_album_to_cd_set(set_id: str, title: str, artist: Optional[str] = None):
    return changer.add_album_to_set(set_id, title, artist)

@app.delete("/cd-sets/{set_id}")
def delete_cd_set(set_id: str):
    return changer.delete_set(set_id)

@app.post("/cd-sets/{set_id}/play")
def play_cd_set(set_id: str, shuffle: bool = False):
    return changer.play_set(set_id, shuffle)

@app.post("/discs/shuffle")
def shuffle_discs():
    return changer.shuffle_discs()

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

@app.delete("/discs")
def eject_all_discs():
    """Stop playback, clear the entire queue, and forget every loaded CD."""
    return changer.eject_all()

@app.delete("/discs/{disc_id}")
@app.post("/discs/{disc_id}/eject")
def eject_disc(disc_id: str):
    return changer.eject(disc_id)

@app.get("/status")
def status():
    speaker = get_speaker()
    volume_target = get_volume_target(speaker)

    return {
        "transport": speaker.get_current_transport_info(),
        "track": speaker.get_current_track_info(),
        "queue_size": speaker.queue_size,
        "volume": volume_target.volume,
        "muted": volume_target.mute,
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
    with changer.lock:
        speaker = get_speaker()
        prepare_playback(speaker)
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
    volume_target = get_volume_target(speaker)
    return {"volume": volume_target.volume, "muted": volume_target.mute}


@app.post("/volume")
def set_volume(level: int = Query(..., ge=0, le=100)):
    speaker = get_speaker()
    volume_target = get_volume_target(speaker)
    volume_target.volume = level
    return {"volume": volume_target.volume, "muted": volume_target.mute}


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
