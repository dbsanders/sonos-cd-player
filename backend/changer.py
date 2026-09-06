"""Single-worker virtual CD changer. Queue positions exposed as 1-based inclusive."""
import json
import os
from pathlib import Path
from threading import RLock
from uuid import uuid4
from fastapi import HTTPException


class Changer:
    def __init__(self, get_speaker, path=None):
        self.get_speaker = get_speaker
        self.path = Path(path or os.environ.get('CHANGER_STATE', '/data/changer.json'))
        self.lock = RLock()
        self.state = json.loads(self.path.read_text()) if self.path.exists() else {'discs': [], 'queue': None, 'uid': None}

    def save(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix('.tmp')
        tmp.write_text(json.dumps(self.state))
        tmp.replace(self.path)

    def queue(self, speaker):
        result = []
        while True:
            page = speaker.get_queue(start=len(result), max_items=100)
            result.extend(t.resources[0].uri for t in page)
            if len(result) >= page.total_matches:
                return result
            if not page:
                raise HTTPException(502, 'Incomplete Sonos queue response')

    def check(self):
        speaker = self.get_speaker()
        if not speaker.is_coordinator:
            raise HTTPException(409, 'Garage must be its group coordinator to use the changer')
        queue = self.queue(speaker)
        if self.state['queue'] is None:
            self.state.update(queue=queue, uid=speaker.uid)
            self.save()
        if queue != self.state['queue'] or speaker.uid != self.state['uid']:
            raise HTTPException(409, 'Sonos queue changed outside the changer. POST /discs/resync to forget disc mappings and retain the current queue.')
        return speaker, queue

    def resolve(self, speaker, title, artist=None):
        albums = list(speaker.music_library.get_albums(search_term=title, complete_result=True))
        if artist:
            albums = [a for a in albums if (getattr(a, 'creator', '') or '').casefold() == artist.casefold()]
        exact = [a for a in albums if a.title.casefold() == title.casefold()]
        albums = exact or albums
        if not albums:
            raise HTTPException(404, 'Album not found')
        if len(albums) > 1:
            raise HTTPException(409, {'message': 'Multiple albums match; specify an exact title and artist', 'matches': [{'title': a.title, 'artist': getattr(a, 'creator', None)} for a in albums]})
        album = albums[0]
        tracks = list(speaker.music_library.get_tracks_for_album(artist=getattr(album, 'creator', None), album=album.title))
        if not tracks:
            raise HTTPException(404, 'Album found, but no tracks found')
        return album, tracks

    def current(self, speaker):
        if not speaker.get_current_media_info().get('uri', '').startswith('x-rincon-queue:'):
            return None
        pos = int(speaker.get_current_track_info().get('playlist_position') or 0)
        return next((d['id'] for d in self.state['discs'] if d['queue_start'] <= pos <= d['queue_end']), None)

    def listing(self):
        with self.lock:
            speaker, queue = self.check()
            return {'discs': self.state['discs'], 'current_disc_id': self.current(speaker), 'queue_size': len(queue), 'position_base': 1}

    def load(self, title, artist=None, play=False):
        with self.lock:
            speaker, before = self.check()
            album, tracks = self.resolve(speaker, title, artist)
            expected = before + [t.resources[0].uri for t in tracks]
            # Check again after library browsing, before modifying the queue.
            self.check()
            for track in tracks:
                speaker.add_to_queue(track)
            actual = self.queue(speaker)
            if actual != expected:
                raise HTTPException(409, 'Queue changed during loading; inspect the queue and resync disc mappings')
            disc = {'id': uuid4().hex, 'album': album.title, 'artist': getattr(album, 'creator', None), 'queue_start': len(before) + 1, 'queue_end': len(actual), 'tracks_added': len(tracks)}
            self.state['discs'].append(disc)
            self.state['queue'] = actual
            self.save()
            if play:
                speaker.play_from_queue(disc['queue_start'] - 1)
            return {'status': 'playing' if play else 'loaded', 'disc': disc}

    def find(self, disc_id):
        disc = next((d for d in self.state['discs'] if d['id'] == disc_id), None)
        if disc is None:
            raise HTTPException(404, 'Disc not found')
        return disc

    def play(self, disc_id):
        with self.lock:
            speaker, _ = self.check()
            disc = self.find(disc_id)
            speaker.play_from_queue(disc['queue_start'] - 1)
            return {'status': 'playing', 'disc': disc, 'transport': speaker.get_current_transport_info()}

    def step(self, direction):
        with self.lock:
            speaker, _ = self.check()
            discs = self.state['discs']
            if not discs:
                raise HTTPException(404, 'No discs loaded')
            current = self.current(speaker)
            if current is None:
                index = 0 if direction == 1 else len(discs) - 1
            else:
                index = (next(i for i, d in enumerate(discs) if d['id'] == current) + direction) % len(discs)
            return self.play(discs[index]['id'])

    def eject(self, disc_id):
        with self.lock:
            speaker, before = self.check()
            disc = self.find(disc_id)
            start, end = disc['queue_start'] - 1, disc['queue_end']
            for index in range(end - 1, start - 1, -1):
                speaker.remove_from_queue(index)
            actual = self.queue(speaker)
            if actual != before[:start] + before[end:]:
                raise HTTPException(409, 'Queue changed during ejection; inspect the queue and resync disc mappings')
            self.state['discs'].remove(disc)
            for remaining in self.state['discs']:
                if remaining['queue_start'] > end:
                    remaining['queue_start'] -= end - start
                    remaining['queue_end'] -= end - start
            self.state['queue'] = actual
            self.save()
            return {'status': 'ejected', 'disc': disc, 'discs': self.state['discs']}

    def resync(self):
        with self.lock:
            speaker = self.get_speaker()
            self.state = {'discs': [], 'queue': self.queue(speaker), 'uid': speaker.uid}
            self.save()
            return {'status': 'resynced', 'discs': [], 'queue_size': len(self.state['queue'])}
