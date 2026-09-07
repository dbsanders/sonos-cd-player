from types import SimpleNamespace as NS
from unittest.mock import Mock

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient
from requests.exceptions import ConnectionError

import app
from changer import Changer
from test_changer import Speaker


def test_speaker_configuration(monkeypatch):
    factory = Mock()
    monkeypatch.setattr(app.soco, 'SoCo', factory)
    monkeypatch.delenv('SONOS_SPEAKER_IP', raising=False)
    app.get_speaker()
    factory.assert_called_with('192.168.1.85')
    monkeypatch.setenv('SONOS_SPEAKER_IP', '192.168.2.252')
    app.get_speaker()
    factory.assert_called_with('192.168.2.252')


def test_grouping_is_optional_and_does_not_rejoin_existing_members(monkeypatch):
    amp = NS(uid='amp', ip_address='192.168.2.252', is_coordinator=True)
    playbar = NS(group=NS(coordinator=NS(uid='playbar')))
    def join(main):
        playbar.group.coordinator = main
    playbar.join = Mock(side_effect=join)
    factory = Mock(return_value=playbar)
    monkeypatch.setattr(app.soco, 'SoCo', factory)
    monkeypatch.delenv('SONOS_GROUP_MEMBERS', raising=False)
    app.prepare_playback(amp)
    factory.assert_not_called()
    monkeypatch.setenv('SONOS_GROUP_MEMBERS', '192.168.2.252, 192.168.2.253,192.168.2.253,')
    app.prepare_playback(amp)
    app.prepare_playback(amp)
    playbar.join.assert_called_once_with(amp)
    assert all(call.args == ('192.168.2.253',) for call in factory.call_args_list)


def test_group_failure_prevents_resume(monkeypatch):
    amp = NS(uid='amp', ip_address='192.168.2.252', is_coordinator=True, play=Mock())
    monkeypatch.setenv('SONOS_GROUP_MEMBERS', '192.168.2.253')
    monkeypatch.setattr(app, 'get_speaker', lambda: amp)
    monkeypatch.setattr(app.soco, 'SoCo', Mock(side_effect=ConnectionError('offline')))
    result = TestClient(app.app).post('/play')
    assert result.status_code == 503
    amp.play.assert_not_called()


def test_wrong_coordinator_does_not_move_queues(monkeypatch):
    amp = NS(is_coordinator=False)
    factory = Mock()
    monkeypatch.setenv('SONOS_GROUP_MEMBERS', '192.168.2.253')
    monkeypatch.setattr(app.soco, 'SoCo', factory)
    with pytest.raises(HTTPException) as error:
        app.prepare_playback(amp)
    assert error.value.status_code == 409
    factory.assert_not_called()


def test_music_actions_group_before_play_but_browsing_and_loading_do_not(tmp_path):
    speaker = Speaker()
    prepare = Mock(side_effect=lambda _: speaker.events.append('group'))
    changer = Changer(lambda: speaker, tmp_path/'state.json', prepare_playback=prepare)
    disc = changer.load('A')['disc']
    changer.listing()
    cd_set = changer.create_set('Music')
    prepare.assert_not_called()
    with pytest.raises(HTTPException):
        changer.play('missing')
    prepare.assert_not_called()
    for action in [lambda: changer.play(disc['id']), lambda: changer.step(1),
                   lambda: changer.load('B', play=True),
                   lambda: changer.play_set(cd_set['id']), changer.shuffle_discs]:
        speaker.events = []
        action()
        assert speaker.events.count('group') == 1
        assert speaker.events.index('group') < speaker.events.index('play')


@pytest.mark.parametrize('action', ['load', 'play', 'set'])
def test_group_failure_preserves_queue_and_disc_assignments(tmp_path, action):
    speaker = Speaker()
    changer = Changer(lambda: speaker, tmp_path/'state.json')
    disc = changer.load('A')['disc']
    cd_set = changer.create_set('Music')
    before = changer.queue(speaker)
    state = changer.path.read_text()
    changer.prepare_playback = Mock(side_effect=HTTPException(503, 'offline'))
    speaker.events = []
    with pytest.raises(HTTPException):
        if action == 'load':
            changer.load('B', play=True)
        elif action == 'play':
            changer.play(disc['id'])
        else:
            changer.play_set(cd_set['id'])
    assert changer.queue(speaker) == before
    assert changer.path.read_text() == state
    assert 'play' not in speaker.events and 'clear' not in speaker.events
