import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient
from changer import Changer
from test_changer import Speaker, track


@pytest.fixture
def setup(tmp_path):
    speaker = Speaker()
    changer = Changer(lambda: speaker, tmp_path / 'changer.json')
    return speaker, changer


def saved_set(changer):
    changer.load('1989 [+digital booklet]')
    changer.load('Björk & Friends')
    return changer.create_set('Weekend + CDs')


def test_save_survives_restart_and_does_not_change_playback(setup):
    speaker, changer = setup
    cd_set = saved_set(changer)
    before = changer.queue(speaker)
    assert 'stop' not in speaker.events and 'play' not in speaker.events
    restored = Changer(lambda: speaker, changer.path)
    assert restored.list_sets()['sets'] == [cd_set]
    changer.resync()
    assert changer.list_sets()['sets'] == [cd_set]
    assert changer.queue(speaker) == before
    restored.delete_set(cd_set['id'])
    assert Changer(lambda: speaker, changer.path).list_sets() == {'sets': []}
    assert changer.queue(speaker) == before


def test_selection_stops_clears_then_plays_in_saved_order_even_when_stale(setup):
    speaker, changer = setup
    cd_set = saved_set(changer)
    speaker.items.append(track('external'))
    speaker.events = []
    result = changer.play_set(cd_set['id'])
    assert result['status'] == 'playing'
    assert speaker.events[:3] == ['stop', 'clear', 'resolve']
    assert speaker.events[-1] == 'play'
    assert speaker.play_mode == 'NORMAL'
    assert speaker.position == 1
    assert changer.queue(speaker) == ['1989 [+digital booklet]0', '1989 [+digital booklet]1', 'Björk & Friends0', 'Björk & Friends1']
    assert [(d['queue_start'], d['queue_end']) for d in result['discs']] == [(1, 2), (3, 4)]
    assert len(changer.listing()['discs']) == 2


def test_shuffle_changes_cd_order_only_and_keeps_saved_order(setup, monkeypatch):
    speaker, changer = setup
    cd_set = saved_set(changer)
    monkeypatch.setattr('changer.random.shuffle', lambda albums: albums.reverse())
    changer.play_set(cd_set['id'], shuffle=True)
    assert changer.queue(speaker) == ['Björk & Friends0', 'Björk & Friends1', '1989 [+digital booklet]0', '1989 [+digital booklet]1']
    assert changer.list_sets()['sets'][0]['albums'][0]['title'] == '1989 [+digital booklet]'
    changer.shuffle_discs()
    assert changer.queue(speaker) == ['1989 [+digital booklet]0', '1989 [+digital booklet]1', 'Björk & Friends0', 'Björk & Friends1']
    assert speaker.play_mode == 'NORMAL'


def test_partial_load_blocks_stale_positions_across_restart_and_can_retry(setup):
    speaker, changer = setup
    cd_set = saved_set(changer)
    speaker.fail_add = True
    speaker.events = []
    with pytest.raises(HTTPException, match='resync'):
        changer.play_set(cd_set['id'])
    assert 'play' not in speaker.events
    restored = Changer(lambda: speaker, changer.path)
    with pytest.raises(HTTPException, match='resync'):
        restored.listing()
    speaker.fail_add = False
    restored.play_set(cd_set['id'])
    assert len(restored.listing()['discs']) == 2


def test_missing_album_does_not_load_a_fuzzy_match(setup):
    speaker, changer = setup
    cd_set = saved_set(changer)
    speaker.get_albums = lambda **kwargs: [type('Album', (), {'title': 'Different album', 'creator': 'artist'})()]
    speaker.events = []
    with pytest.raises(HTTPException, match='Album not found'):
        changer.play_set(cd_set['id'])
    assert changer.queue(speaker) == []
    assert 'play' not in speaker.events


def test_validation_and_failed_save_leave_sets_unchanged(setup, monkeypatch):
    speaker, changer = setup
    with pytest.raises(HTTPException): changer.create_set('Empty')
    cd_set = saved_set(changer)
    for name in (' ', 'x' * 81, ' weekend + cds '):
        with pytest.raises(HTTPException): changer.create_set(name)
    before = changer.queue(speaker)
    with pytest.raises(HTTPException): changer.play_set('missing')
    assert changer.queue(speaker) == before
    def fail(): raise OSError('disk full')
    monkeypatch.setattr(changer, 'save_sets', fail)
    with pytest.raises(OSError): changer.create_set('New')
    with pytest.raises(OSError): changer.delete_set(cd_set['id'])
    assert changer.list_sets()['sets'] == [cd_set]


def test_api(setup, monkeypatch):
    import app
    speaker, changer = setup
    monkeypatch.setattr(app, 'changer', changer)
    client = TestClient(app.app)
    changer.load('A')
    response = client.post('/cd-sets', params={'name': 'Road + Trip'})
    assert response.status_code == 200
    set_id = response.json()['id']
    assert client.get('/cd-sets').json()['sets'][0]['name'] == 'Road + Trip'
    assert client.post(f'/cd-sets/{set_id}/play', params={'shuffle': True}).status_code == 200
    assert client.post('/discs/shuffle').status_code == 200
    assert client.delete(f'/cd-sets/{set_id}').status_code == 200
    assert client.get('/cd-sets').json() == {'sets': []}


def test_overwrite_preserves_identity_and_playback_and_survives_restart(setup):
    speaker, changer = setup
    original = saved_set(changer)
    changer.eject_all()
    changer.load('New album')
    before = changer.queue(speaker)
    speaker.events = []
    updated = changer.overwrite_set(original['id'])
    assert updated['id'] == original['id']
    assert updated['name'] == original['name']
    assert updated['albums'] == [{'title': 'New album', 'artist': 'artist'}]
    assert speaker.events == []
    assert changer.queue(speaker) == before
    assert Changer(lambda: speaker, changer.path).list_sets()['sets'] == [updated]
    changer.play_set(updated['id'])
    assert changer.queue(speaker) == ['New album0', 'New album1']


def test_overwrite_validation_and_disk_failure_preserve_original(setup, monkeypatch):
    speaker, changer = setup
    original = saved_set(changer)
    with pytest.raises(HTTPException): changer.overwrite_set('missing')
    changer.eject_all()
    with pytest.raises(HTTPException): changer.overwrite_set(original['id'])
    changer.load('New album')
    def fail(): raise OSError('disk full')
    monkeypatch.setattr(changer, 'save_sets', fail)
    with pytest.raises(OSError): changer.overwrite_set(original['id'])
    assert changer.list_sets()['sets'] == [original]
    assert Changer(lambda: speaker, changer.path).list_sets()['sets'] == [original]
    speaker.items.append(track('external'))
    with pytest.raises(HTTPException): changer.overwrite_set(original['id'])
    assert changer.list_sets()['sets'] == [original]


def test_overwrite_api(setup, monkeypatch):
    import app
    speaker, changer = setup
    monkeypatch.setattr(app, 'changer', changer)
    original = saved_set(changer)
    changer.load('C')
    client = TestClient(app.app)
    response = client.put('/cd-sets/' + original['id'])
    assert response.status_code == 200
    assert len(response.json()['albums']) == 3
    assert len(client.get('/cd-sets').json()['sets']) == 1
