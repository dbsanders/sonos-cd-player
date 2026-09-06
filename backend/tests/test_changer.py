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
    def get_queue(self, start=0, max_items=100):
        q = Queue(self.items[start:start+max_items])
        q.total_matches = len(self.items)
        return q
    def get_albums(self, search_term, **kwargs):
        return [] if search_term == 'missing' else [NS(title=search_term, creator='artist')]
    def get_tracks_for_album(self, artist, album, full_album_art_uri=False):
        return [track(album + str(i)) for i in range(2)]
    def add_to_queue(self, t):
        if self.fail_add and t.resources[0].uri.endswith('1'):
            raise RuntimeError('network failure')
        self.items.append(t)
    def remove_from_queue(self, index):
        self.items.pop(index)
    def play_from_queue(self, index):
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
    client=TestClient(app.app)
    a=client.post('/discs/load',params={'title':'A'}).json()['disc']
    assert client.get('/discs').status_code==200
    assert client.post('/discs/'+a['id']+'/play').status_code==200
    assert client.post('/discs/next').status_code==200
    assert client.post('/discs/previous').status_code==200
    assert client.delete('/discs/'+a['id']).status_code==200
    assert client.post('/play-album',params={'title':'B'}).json()['status']=='playing'
