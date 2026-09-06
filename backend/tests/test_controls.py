import os
os.environ.setdefault('CHANGER_STATE', '/tmp/sonos-controls-test-state.json')
import app
from fastapi.testclient import TestClient

class Speaker:
    volume = 17
    mute = False
    queue_size = 3
    state = 'PLAYING'
    def pause(self): self.state = 'PAUSED_PLAYBACK'
    def play(self): self.state = 'PLAYING'
    def get_current_transport_info(self): return {'current_transport_state':self.state}
    def get_current_track_info(self): return {'title':'Example','uri':'example'}

def test_controls(monkeypatch):
    speaker = Speaker()
    monkeypatch.setattr(app, 'get_speaker', lambda:speaker)
    client = TestClient(app.app)
    assert client.get('/status').json()['volume']==17
    assert client.post('/pause').json()['transport']['current_transport_state']=='PAUSED_PLAYBACK'
    assert client.post('/play').json()['after']['current_transport_state']=='PLAYING'
    for level in (0,35,100):
        assert client.post('/volume',params={'level':level}).json()['volume']==level
    for level in (-1,101,'oops',5.5):
        assert client.post('/volume',params={'level':level}).status_code==422
        assert speaker.volume==100
    assert client.post('/volume').status_code==422
    assert client.get('/volume').json()=={'volume':100,'muted':False}

def test_track_navigation(monkeypatch):
    speaker = Speaker()
    calls = []
    speaker.next = lambda: calls.append('next')
    speaker.previous = lambda: calls.append('previous')
    monkeypatch.setattr(app, 'get_speaker', lambda:speaker)
    client = TestClient(app.app)
    assert client.post('/tracks/next').status_code == 200
    assert client.post('/tracks/previous').status_code == 200
    assert calls == ['next','previous']
    def unavailable():
        raise app.soco.exceptions.SoCoUPnPException('Transition not available', '701', '')
    speaker.next = unavailable
    response = client.post('/tracks/next')
    assert response.status_code == 409
    assert 'cannot skip' in response.json()['detail']
