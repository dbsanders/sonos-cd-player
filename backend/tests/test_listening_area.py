from itertools import permutations
from types import SimpleNamespace as NS

import pytest
from fastapi.testclient import TestClient
from requests.exceptions import ConnectionError

import app
from changer import Changer
from test_changer import Speaker, track


class Room(Speaker):
    def __init__(self, ip):
        super().__init__()
        self.ip_address = self.uid = ip
        self.player_name = ip
        self.group = NS(coordinator=self, members={self}, volume=25, mute=False)
        self.online = True
        self.state = 'STOPPED'

    @property
    def is_coordinator(self):
        return self.group.coordinator is self

    def unjoin(self):
        self.group.members.remove(self)
        self.group = NS(coordinator=self, members={self}, volume=25, mute=False)
        self.state = 'STOPPED'

    def join(self, leader):
        self.unjoin()
        self.group = leader.group
        self.group.members.add(self)

    def get_current_transport_info(self):
        if not self.online:
            raise ConnectionError('offline')
        return {'current_transport_state': self.state}

    def stop(self):
        super().stop()
        self.state = 'STOPPED'

    def play(self):
        self.state = 'PLAYING'

    def play_from_queue(self, index, start=True):
        self.position = index + 1
        self.state = 'PLAYING' if start else 'STOPPED'
        self.events.append('play' if start else 'select')


@pytest.fixture
def installation(tmp_path, monkeypatch):
    amp, bar, bed = [Room('192.168.2.' + str(n)) for n in (252, 253, 254)]
    rooms = {r.ip_address: r for r in (amp, bar, bed)}
    monkeypatch.setenv('SONOS_SPEAKER_IP', amp.ip_address)
    monkeypatch.setenv('SONOS_GROUP_MEMBERS', bar.ip_address)
    monkeypatch.setenv('SONOS_UPSTAIRS_IP', bed.ip_address)
    monkeypatch.setattr(app.soco, 'SoCo', lambda ip: rooms[ip])
    changer = Changer(lambda: app.get_speaker(), tmp_path / 'changer.json', app.prepare_playback)
    monkeypatch.setattr(app, 'changer', changer)
    disc = changer.load('A', play=True)['disc']
    return TestClient(app.app), changer, amp, bar, bed, disc


@pytest.mark.parametrize('origin,destination', list(permutations(['upstairs', 'downstairs', 'both'], 2)))
def test_all_switches_preserve_magazine_and_stop(installation, origin, destination):
    client, changer, amp, bar, bed, disc = installation
    assert client.put('/listening-area', json={'area': origin}).status_code == 200
    client.post('/play')
    expected = changer.state['queue'][:]
    response = client.put('/listening-area', json={'area': destination})
    assert response.status_code == 200, response.text
    assert response.json()['area'] == destination
    leader = bed if destination == 'upstairs' else amp
    selected = {'upstairs': {bed}, 'downstairs': {amp, bar}, 'both': {amp, bar, bed}}[destination]
    assert leader.group.members == selected
    assert leader.state == 'STOPPED'
    assert leader.play_mode == 'REPEAT_ALL'
    assert changer.queue(leader) == expected
    assert changer.listing()['discs'] == [disc]
    assert leader.position == disc['queue_start']
    assert client.get('/speaker').json()['ip'] == leader.ip_address
    assert client.post('/volume', params={'level': 19}).status_code == 200
    assert leader.group.volume == 19
    assert client.post('/play').status_code == 200
    assert leader.state == 'PLAYING'


def test_selection_survives_restart_and_queue_replacement(installation, monkeypatch):
    client, changer, amp, bar, bed, disc = installation
    client.put('/listening-area', json={'area': 'upstairs'})
    cd_set = changer.create_set('Night')
    changer.play_set(cd_set['id'])
    changer.eject_all()
    restored = Changer(lambda: app.get_speaker(), changer.path, app.prepare_playback)
    monkeypatch.setattr(app, 'changer', restored)
    assert client.get('/listening-area').json()['area'] == 'upstairs'
    assert app.get_speaker() is bed
    assert restored.listing()['discs'] == []


def test_offline_selected_room_does_not_stop_current_playback(installation):
    client, changer, amp, bar, bed, disc = installation
    bed.online = False
    before = amp.events[:]
    assert client.put('/listening-area', json={'area': 'upstairs'}).status_code == 503
    assert amp.events == before
    assert changer.listening_area == 'downstairs'
    assert client.post('/play').status_code == 200


def test_failed_queue_copy_keeps_original_magazine(installation):
    client, changer, amp, bar, bed, disc = installation
    bed.fail_add = True
    assert client.put('/listening-area', json={'area': 'upstairs'}).status_code == 503
    assert changer.listening_area == 'downstairs'
    assert changer.listing()['discs'] == [disc]
    assert bed.state == 'STOPPED'
    bed.fail_add = False
    assert client.put('/listening-area', json={'area': 'upstairs'}).status_code == 200


def test_repeat_selection_and_reads_do_not_interrupt(installation):
    client, changer, amp, bar, bed, disc = installation
    before = amp.events[:]
    assert client.get('/listening-area').status_code == 200
    assert client.put('/listening-area', json={'area': 'downstairs'}).status_code == 200
    assert amp.events == before


def test_validation_and_disabled_configuration(installation, monkeypatch):
    client, changer, amp, bar, bed, disc = installation
    assert client.put('/listening-area', json={'area': 'attic'}).status_code == 422
    monkeypatch.delenv('SONOS_UPSTAIRS_IP')
    assert len(client.get('/listening-area').json()['areas']) == 1
    assert client.put('/listening-area', json={'area': 'upstairs'}).status_code == 409


def test_stale_queue_is_not_copied(installation):
    client, changer, amp, bar, bed, disc = installation
    amp.items.pop()
    before = bed.items[:]
    assert client.put('/listening-area', json={'area': 'upstairs'}).status_code == 409
    assert bed.items == before


def test_large_queue_and_empty_queue(installation):
    client, changer, amp, bar, bed, disc = installation
    amp.items = [track(str(n)) for n in range(205)]
    changer.resync()
    assert client.put('/listening-area', json={'area': 'upstairs'}).status_code == 200
    assert changer.queue(bed) == [str(n) for n in range(205)]
    changer.eject_all()
    assert client.put('/listening-area', json={'area': 'downstairs'}).status_code == 200
    assert amp.items == []
    assert amp.state == 'STOPPED'


def test_failed_switch_after_regrouping_blocks_unverified_playback(installation, monkeypatch):
    client, changer, amp, bar, bed, disc = installation
    client.put('/listening-area', json={'area': 'upstairs'})
    def fail_selection(*args, **kwargs):
        raise ConnectionError('connection lost after grouping')
    monkeypatch.setattr(amp, 'play_from_queue', fail_selection)
    assert client.put('/listening-area', json={'area': 'both'}).status_code == 503
    assert changer.listening_area == 'upstairs'
    assert changer.state['incomplete']
    assert client.post('/play').status_code == 409
    restored = Changer(lambda: app.get_speaker(), changer.path)
    assert restored.state['incomplete']


def test_interrupted_transfer_is_marked_on_disk_before_mutations(installation, monkeypatch):
    client, changer, amp, bar, bed, disc = installation
    class SimulatedCrash(BaseException):
        pass
    def crash():
        restored = Changer(lambda: app.get_speaker(), changer.path)
        assert restored.state['incomplete']
        assert restored.listening_area == 'downstairs'
        raise SimulatedCrash()
    monkeypatch.setattr(amp, 'stop', crash)
    with changer.lock, pytest.raises(SimulatedCrash):
        changer.switch_area('upstairs', bed, lambda speaker: None)


def test_play_reconciles_external_grouping(installation):
    client, changer, amp, bar, bed, disc = installation
    bed.join(amp)
    assert client.post('/play').status_code == 200
    assert amp.group.members == {amp, bar}
    assert bed.group.members == {bed}
    assert bed.state == 'STOPPED'
