import os
from functools import wraps
from typing import Literal, Optional
from urllib.parse import urljoin

from fastapi import FastAPI, HTTPException, Query
import soco
from pydantic import BaseModel
from requests.exceptions import RequestException

app = FastAPI(title="Sonos CD Player")


def serialized(function):
    @wraps(function)
    def wrapped(*args, **kwargs):
        with changer.lock:
            return function(*args, **kwargs)
    return wrapped


def get_speaker():
    if changer.listening_area == 'upstairs':
        bedroom = os.environ.get('SONOS_UPSTAIRS_IP')
        if not bedroom:
            raise HTTPException(409, 'The saved Upstairs selection requires SONOS_UPSTAIRS_IP')
        return soco.SoCo(bedroom)
    return soco.SoCo(os.environ.get("SONOS_SPEAKER_IP", "192.168.1.85"))


def get_volume_target(speaker):
    """Use Sonos group volume when grouped, or the speaker for a single-room group."""
    return getattr(speaker, "group", None) or speaker


def album_art_url(speaker, uri):
    """Resolve Sonos's usual relative artwork paths against the configured player."""
    if not uri:
        return None
    return urljoin(f"http://{speaker.ip_address}:1400/", uri)


def configured_members():
    return list(dict.fromkeys(ip.strip() for ip in
        os.environ.get('SONOS_GROUP_MEMBERS', '').split(',') if ip.strip()))


def prepare_playback(speaker, area=None):
    """Join configured rooms only for an explicit music playback request."""
    area = area or changer.listening_area
    bedroom = os.environ.get('SONOS_UPSTAIRS_IP')
    members = [] if area == 'upstairs' else configured_members()
    if area == 'both' and bedroom:
        members = list(dict.fromkeys([*members, bedroom]))
    if not members and not bedroom:
        return
    try:
        if not speaker.is_coordinator:
            raise HTTPException(409, "The configured main speaker must lead the Sonos group. "
                                "In Sonos, ungroup it and select it first before adding other rooms.")
        if bedroom:
            managed = {os.environ.get('SONOS_SPEAKER_IP', '192.168.1.85'),
                       bedroom, *configured_members()}
            selected = {speaker.ip_address, *members}
            for member in list(speaker.group.members):
                if member.ip_address in managed - selected:
                    member.unjoin()
                    member.stop()
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
@serialized
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
    by_album = {}

    for album in items:
        entry = {
            "title": album.title,
            "artist": getattr(album, "creator", None),
            "album_art_uri": album_art_url(speaker, getattr(album, "album_art_uri", None)),
            "uri": getattr(album, "resources", [None])[0].uri
                if getattr(album, "resources", None)
                else None,
        }
        # Sonos can return the same album multiple times with artwork pointing
        # at different tracks. Repeated identities break SwiftUI's lazy grids.
        key = (entry['uri'] or entry['title'], entry['artist'] or '')
        if key in by_album:
            if not by_album[key]['album_art_uri']:
                by_album[key]['album_art_uri'] = entry['album_art_uri']
            continue
        by_album[key] = entry
        result.append(entry)

    return {
        "count": len(result),
        "albums": result,
    }

from changer import Changer
changer = Changer(lambda: get_speaker(), prepare_playback=prepare_playback)


class ListeningAreaRequest(BaseModel):
    area: Literal['upstairs', 'downstairs', 'both']


def listening_area_info():
    areas = [{'id': 'downstairs', 'name': 'Downstairs', 'speakers': list(dict.fromkeys([
        os.environ.get('SONOS_SPEAKER_IP', '192.168.1.85'), *configured_members()]))}]
    bedroom = os.environ.get('SONOS_UPSTAIRS_IP')
    if bedroom:
        areas.append({'id': 'upstairs', 'name': 'Upstairs', 'speakers': [bedroom]})
        areas.append({'id': 'both', 'name': 'Both', 'speakers': [*areas[0]['speakers'], bedroom]})
    return {'area': changer.listening_area, 'areas': areas}


@app.get('/listening-area')
def listening_area():
    with changer.lock:
        return listening_area_info()


@app.put('/listening-area')
def set_listening_area(request: ListeningAreaRequest):
    with changer.lock:
        if request.area != 'downstairs' and not os.environ.get('SONOS_UPSTAIRS_IP'):
            raise HTTPException(409, 'No upstairs speaker is configured')
        if request.area != changer.listening_area:
            ip = (os.environ['SONOS_UPSTAIRS_IP'] if request.area == 'upstairs'
                  else os.environ.get('SONOS_SPEAKER_IP', '192.168.1.85'))
            destination = soco.SoCo(ip)
            try:
                # Check selected rooms before stopping existing playback. Excluded
                # standalone rooms need not be online.
                for room in next(a['speakers'] for a in listening_area_info()['areas']
                                 if a['id'] == request.area):
                    soco.SoCo(room).get_current_transport_info()
                changer.switch_area(request.area, destination,
                                    lambda speaker: prepare_playback(speaker, request.area))
            except (soco.exceptions.SoCoException, RequestException, OSError) as exc:
                raise HTTPException(503, 'Selected speakers are unavailable. Check them and retry.') from exc
        return listening_area_info()

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

@app.post("/cd-sets/{set_id}/refresh")
def refresh_cd_set(set_id: str):
    """Refresh saved Sonos album artists without changing playback."""
    return changer.refresh_set(set_id)

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
@serialized
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
        if changer.state.get('incomplete'):
            raise HTTPException(409, 'A queue operation did not finish. Resync or reload a CD Set before playing.')
        speaker = get_speaker()
        prepare_playback(speaker)
        speaker.play_mode = 'REPEAT_ALL'
        return {
            "before": speaker.get_current_transport_info(),
            "result": speaker.play(),
            "after": speaker.get_current_transport_info(),
        }

@app.post("/pause")
@serialized
def pause():
    speaker = get_speaker()
    speaker.pause()
    return {"transport": speaker.get_current_transport_info()}


@serialized
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
@serialized
def volume():
    speaker = get_speaker()
    volume_target = get_volume_target(speaker)
    return {"volume": volume_target.volume, "muted": volume_target.mute}


@app.post("/volume")
@serialized
def set_volume(level: int = Query(..., ge=0, le=100)):
    speaker = get_speaker()
    volume_target = get_volume_target(speaker)
    volume_target.volume = level
    return {"volume": volume_target.volume, "muted": volume_target.mute}


@app.get("/transport")
@serialized
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
