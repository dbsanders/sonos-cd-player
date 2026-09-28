from types import SimpleNamespace as NS
import pytest
from fastapi import HTTPException
from changer import Changer


def track(uri):
    return NS(resources=[NS(uri=uri)])

class Queue(list):
    pass

class Speaker:
    uid = 'garage'
    is_coordinator = True
    def __init__(self):
        self.items = [track('existing')]
        self.position = 1
        self.music_library = self
        self.fail_add = False
        self.batch_calls = []
        self.events = []
        self.play_mode = 'SHUFFLE'
    def stop(self): self.events.append('stop')
    def play(self): self.events.append('resume')
    def clear_queue(self):
        self.events.append('clear')
        self.items = []
    def get_queue(self, start=0, max_items=100):
        q = Queue(self.items[start:start+max_items])
        q.total_matches = len(self.items)
        return q
    def get_albums(self, search_term, **kwargs):
        self.events.append('resolve')
        return [] if search_term == 'missing' else [NS(title=search_term, creator='artist')]
    def get_tracks_for_album(self, artist, album, full_album_art_uri=False):
        return [track(album + str(i)) for i in range(2)]
    def add_to_queue(self, t):
        if self.fail_add and t.resources[0].uri.endswith('1'):
            raise RuntimeError('network failure')
        self.items.append(t)
    def add_multiple_to_queue(self, items):
        items = list(items)
        self.batch_calls.append([item.resources[0].uri for item in items])
        for item in items:
            self.add_to_queue(item)
    def remove_from_queue(self, index):
        self.items.pop(index)
    def play_from_queue(self, index):
        self.events.append('play')
        self.position = index+1
    def get_current_track_info(self):
        return {'playlist_position': str(self.position)}
    def get_current_media_info(self):
        return {'uri': 'x-rincon-queue:garage#0'}
    def get_current_transport_info(self):
        return {'current_transport_state': 'PLAYING'}

@pytest.fixture
def setup(tmp_path):
    s = Speaker()
    return s, Changer(lambda:s, tmp_path/'state.json')

def test_lifecycle(setup):
    s,c = setup
    a=c.load('A')['disc']; b=c.load('B')['disc']
    assert s.play_mode == 'REPEAT_ALL'
    assert (a['queue_start'],a['queue_end']) == (2,3)
    assert (b['queue_start'],b['queue_end']) == (4,5)
    assert s.items[0].resources[0].uri == 'existing'
    assert s.position == 1
    c.play(a['id']); assert s.position == 2
    assert c.step(1)['disc']['id'] == b['id']
    assert c.step(1)['disc']['id'] == a['id']
    assert c.step(-1)['disc']['id'] == b['id']
    restored = Changer(lambda:s,c.path)
    assert len(restored.listing()['discs']) == 2
    c.eject(a['id'])
    assert (b['queue_start'],b['queue_end']) == (2,3)
    assert [t.resources[0].uri for t in s.items] == ['existing','B0','B1']
    c.eject(b['id']); assert len(s.items) == 1
    with pytest.raises(HTTPException) as e: c.step(1)
    assert e.value.status_code == 404

def test_stale_and_resync(setup):
    s,c=setup
    a=c.load('A')['disc']
    s.items.insert(0,track('external'))
    with pytest.raises(HTTPException) as e:c.eject(a['id'])
    assert e.value.status_code == 409
    assert len(s.items)==4
    c.resync(); assert c.listing()['discs']==[]
    with pytest.raises(HTTPException):c.play(a['id'])

def test_partial_failure_blocks_future_operations(setup):
    s,c=setup
    s.fail_add=True
    with pytest.raises(RuntimeError):c.load('A')
    with pytest.raises(HTTPException) as e:c.load('B')
    assert e.value.status_code==409

def test_paging_and_not_found(setup):
    s,c=setup
    s.items=[track(str(i)) for i in range(205)]
    assert c.listing()['queue_size']==205
    with pytest.raises(HTTPException) as e:c.load('missing')
    assert e.value.status_code==404
    assert len(s.items)==205

def test_http_endpoints(setup,monkeypatch):
    import os
    s,c=setup
    monkeypatch.setenv('CHANGER_STATE', str(c.path))
    import app
    from fastapi.testclient import TestClient
    monkeypatch.setattr(app,'changer',c)
    monkeypatch.setattr(app,'get_speaker',lambda:s)
    client=TestClient(app.app)
    a=client.post('/discs/load',params={'title':'A'}).json()['disc']
    assert client.get('/discs').status_code==200
    assert client.post('/discs/'+a['id']+'/play').status_code==200
    assert client.post('/discs/next').status_code==200
    assert client.post('/discs/previous').status_code==200
    assert client.delete('/discs/'+a['id']).status_code==200
    assert client.post('/play-album',params={'title':'B'}).json()['status']=='playing'
    s.play_mode = 'NORMAL'
    assert client.post('/play').status_code == 200
    assert s.play_mode == 'REPEAT_ALL'


def test_eject_all_clears_entire_queue_once_and_persists(setup, monkeypatch):
    s, c = setup
    c.load('A'); c.load('B')
    def unexpected_remove(index):
        pytest.fail('Bulk eject must not remove individual tracks')
    monkeypatch.setattr(s, 'remove_from_queue', unexpected_remove)
    assert c.eject_all() == {'status': 'ejected', 'discs': []}
    assert s.events.count('clear') == 1
    assert s.events[-2:] == ['stop', 'clear']
    assert s.items == []  # Includes the pre-existing, untracked queue entry.
    restored = Changer(lambda: s, c.path)
    assert restored.listing()['discs'] == []
    assert restored.state['queue'] == []
    assert c.load('C')['disc']['queue_start'] == 1


@pytest.mark.parametrize('failure', ['before_clear', 'after_clear', 'not_empty'])
def test_eject_all_failure_does_not_trust_disc_positions(setup, monkeypatch, failure):
    s, c = setup
    c.load('A')
    def failed_clear():
        if failure == 'not_empty':
            return
        if failure == 'after_clear':
            s.items = []
        raise RuntimeError('Connection lost')
    monkeypatch.setattr(s, 'clear_queue', failed_clear)
    with pytest.raises(HTTPException) as error:
        c.eject_all()
    assert error.value.status_code == 409
    restored = Changer(lambda: s, c.path)
    with pytest.raises(HTTPException):
        restored.load('B')
    restored.resync()
    assert restored.listing()['discs'] == []


def test_eject_all_endpoint(setup, monkeypatch):
    s, c = setup
    monkeypatch.setenv('CHANGER_STATE', str(c.path))
    import app
    from fastapi.testclient import TestClient
    monkeypatch.setattr(app, 'changer', c)
    c.load('A')
    response = TestClient(app.app).delete('/discs')
    assert response.status_code == 200
    assert response.json()['discs'] == []
    assert s.items == []
