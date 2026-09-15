"""Single-worker virtual CD changer. Queue positions exposed as 1-based inclusive."""
import json
import os
import random
from datetime import datetime, timezone
from pathlib import Path
from threading import RLock
from uuid import uuid4
from fastapi import HTTPException


class Changer:
    def __init__(self, get_speaker, path=None, prepare_playback=None):
        self.get_speaker = get_speaker
        self.prepare_playback = prepare_playback or (lambda speaker: None)
        self.path = Path(path or os.environ.get('CHANGER_STATE', '/data/changer.json'))
        self.lock = RLock()
        self.state = json.loads(self.path.read_text()) if self.path.exists() else {'discs': [], 'queue': None, 'uid': None}
        self.sets_path = self.path.with_name('cd-sets.json')
        self.sets = json.loads(self.sets_path.read_text()) if self.sets_path.exists() else []

    def save_sets(self):
        self.sets_path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.sets_path.with_suffix('.tmp')
        tmp.write_text(json.dumps(self.sets, ensure_ascii=False))
        tmp.replace(self.sets_path)

    def list_sets(self):
        with self.lock:
            return {'sets': self.sets}

    def validate_set_name(self, name):
        name = name.strip()
        if not name or len(name) > 80:
            raise HTTPException(422, 'Enter a CD Set name between 1 and 80 characters')
        return name

    def album_entry(self, title, artist=None):
        title = title.strip()
        if not title:
            raise HTTPException(422, 'Choose a CD to add')
        return {'title': title, 'artist': artist.strip() if artist and artist.strip() else None}

    def same_album(self, left, right):
        return (left['title'].casefold() == right['title'].casefold()
                and (left.get('artist') or '').casefold() == (right.get('artist') or '').casefold())

    def create_set_record(self, name, albums):
        if any(s['name'].casefold() == name.casefold() for s in self.sets):
            raise HTTPException(409, 'A CD Set with that name already exists')
        cd_set = {'id': uuid4().hex, 'name': name,
                  'created_at': datetime.now(timezone.utc).isoformat(),
                  'albums': albums}
        self.sets.append(cd_set)
        try:
            self.save_sets()
        except Exception:
            self.sets.remove(cd_set)
            raise
        return cd_set

    def create_set(self, name):
        name = self.validate_set_name(name)
        with self.lock:
            self.check()
            if not self.state['discs']:
                raise HTTPException(409, 'Load some CDs before saving a set')
            albums = [{'title': d['album'], 'artist': d['artist']} for d in self.state['discs']]
            return self.create_set_record(name, albums)

    def create_set_from_album(self, name, title, artist=None):
        name = self.validate_set_name(name)
        album = self.album_entry(title, artist)
        with self.lock:
            return self.create_set_record(name, [album])

    def add_album_to_set(self, set_id, title, artist=None):
        album = self.album_entry(title, artist)
        with self.lock:
            existing = self.find_set(set_id)
            if any(self.same_album(saved, album) for saved in existing['albums']):
                raise HTTPException(409, f'{title} is already in {existing["name"]}')
            existing['albums'].append(album)
            try:
                self.save_sets()
            except Exception:
                existing['albums'].pop()
                raise
            return existing

    def overwrite_set(self, set_id):
        with self.lock:
            existing = self.find_set(set_id)
            self.check()
            if not self.state['discs']:
                raise HTTPException(409, 'Load some CDs before saving a set')
            replacement = {**existing, 'albums': [
                {'title': d['album'], 'artist': d['artist']} for d in self.state['discs']]}
            index = self.sets.index(existing)
            self.sets[index] = replacement
            try:
                self.save_sets()
            except Exception:
                self.sets[index] = existing
                raise
            return replacement

    def find_set(self, set_id):
        cd_set = next((s for s in self.sets if s['id'] == set_id), None)
        if cd_set is None:
            raise HTTPException(404, 'CD Set not found')
        return cd_set

    def delete_set(self, set_id):
        with self.lock:
            cd_set = self.find_set(set_id)
            before = self.sets[:]
            self.sets.remove(cd_set)
            try:
                self.save_sets()
            except Exception:
                self.sets = before
                raise
            return {'status': 'deleted'}

    def play_set(self, set_id, shuffle=False):
        with self.lock:
            cd_set = self.find_set(set_id)
            return self.replace_discs(cd_set['albums'], shuffle)

    def shuffle_discs(self):
        with self.lock:
            self.check()
            albums = [{'title': d['album'], 'artist': d['artist']} for d in self.state['discs']]
            return self.replace_discs(albums, shuffle=True)

    def replace_discs(self, albums, shuffle=False):
        """Caller holds the lock. Explicit replacement also recovers stale queues."""
        albums = list(albums)
        if not albums:
            raise HTTPException(409, 'No CDs to play')
        speaker = self.get_speaker()
        if not speaker.is_coordinator:
            raise HTTPException(409, 'The configured main speaker must be its group coordinator to use the changer')
        if shuffle:
            random.shuffle(albums)
        self.prepare_playback(speaker)
        # Persist before touching Sonos: a crash/partial failure must not leave
        # old magazine positions trusted, even if the resulting queue is empty.
        self.state = {'discs': [], 'queue': [], 'uid': speaker.uid, 'incomplete': True}
        self.save()
        try:
            speaker.stop()
            speaker.clear_queue()
            speaker.play_mode = 'NORMAL'
            expected, discs = [], []
            for identity in albums:
                album, tracks = self.resolve(speaker, identity['title'], identity.get('artist'))
                if album.title.casefold() != identity['title'].casefold():
                    raise HTTPException(404, f"Album not found: {identity['title']}")
                start = len(expected) + 1
                for track in tracks:
                    speaker.add_to_queue(track)
                    expected.append(track.resources[0].uri)
                discs.append({'id': uuid4().hex, 'album': album.title,
                              'artist': getattr(album, 'creator', None),
                              'queue_start': start, 'queue_end': len(expected),
                              'tracks_added': len(tracks)})
            if self.queue(speaker) != expected:
                raise HTTPException(409, 'Sonos queue changed while loading the CDs')
            self.state = {'discs': discs, 'queue': expected, 'uid': speaker.uid}
            self.save()
        except Exception as exc:
            self.state['incomplete'] = True
            self.save()
            detail = exc.detail if isinstance(exc, HTTPException) else 'Sonos could not finish loading the CDs'
            raise HTTPException(409, f'{detail}. Select a CD Set to try again, or resync disc tracking. Playback was not started.') from exc
        speaker.play_from_queue(0)
        return {'status': 'playing', 'discs': discs}

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
        if self.state.get('incomplete'):
            raise HTTPException(409, 'A queue operation did not finish. Select a CD Set to try again, or resync disc tracking.')
        speaker = self.get_speaker()
        if not speaker.is_coordinator:
            raise HTTPException(409, 'The configured main speaker must be its group coordinator to use the changer')
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
            if play:
                self.prepare_playback(speaker)
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
            self.prepare_playback(speaker)
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

    def eject_all(self):
        with self.lock:
            speaker, _ = self.check()
            # Persist uncertainty before changing Sonos so a failed request or
            # restart cannot leave old disc positions trusted.
            self.state['incomplete'] = True
            self.save()
            try:
                speaker.stop()
                speaker.clear_queue()
                if self.queue(speaker):
                    raise HTTPException(409, 'Sonos queue was not empty after ejecting all CDs')
            except Exception as exc:
                detail = exc.detail if isinstance(exc, HTTPException) else 'Sonos could not finish clearing the queue'
                raise HTTPException(409, f'{detail}. Resync disc tracking before continuing.') from exc
            self.state = {'discs': [], 'queue': [], 'uid': speaker.uid}
            self.save()
            return {'status': 'ejected', 'discs': []}

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
