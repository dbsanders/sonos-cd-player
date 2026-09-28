from types import SimpleNamespace

import app
from fastapi.testclient import TestClient


def album(title, artist, uri=None, art=None):
    return SimpleNamespace(title=title, creator=artist, album_art_uri=art,
                           resources=[SimpleNamespace(uri=uri)] if uri else [])


def library_response(monkeypatch, items):
    speaker = SimpleNamespace(ip_address='192.168.2.252', music_library=SimpleNamespace(
        get_albums=lambda **kwargs: items))
    monkeypatch.setattr(app, 'get_speaker', lambda: speaker)
    return TestClient(app.app).get('/albums').json()


def test_track_artwork_variants_do_not_duplicate_album_cards(monkeypatch):
    response = library_response(monkeypatch, [
        album('Legendary Tenors', 'Mario Lanza', 'album:mario'),
        album('Legendary Tenors', 'Mario Lanza', 'album:mario', '/getaa?track=14'),
        album('Legendary Tenors', 'Mario Lanza', 'album:mario', '/getaa?track=16'),
        album('Gershwin', 'Mario-Ratko Delorko', 'album:gershwin'),
    ])
    assert response['count'] == 2
    assert [a['title'] for a in response['albums']] == ['Legendary Tenors', 'Gershwin']
    assert response['albums'][0]['album_art_uri'].endswith('/getaa?track=14')


def test_distinct_artists_and_album_resources_are_preserved(monkeypatch):
    response = library_response(monkeypatch, [
        album('Greatest Hits', 'Artist A', 'album:hits'),
        album('Greatest Hits', 'Artist B', 'album:hits'),
        album('Greatest Hits', 'Artist A', 'album:other-edition'),
    ])
    assert response['count'] == 3


def test_albums_without_resources_use_title_and_artist(monkeypatch):
    response = library_response(monkeypatch, [
        album('One', None), album('One', None, art='/getaa?track=2'),
        album('Two', None), album('One', 'Artist'),
    ])
    assert response['count'] == 3
