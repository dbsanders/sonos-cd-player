# Riverside Pi deployment

Requires Raspberry Pi OS Lite 64-bit and Docker Engine. In the Pi's root SSH
session, install Docker with `apt update && apt install -y docker.io`, then run
`systemctl enable --now docker`. The Pi and Sonos speakers must be able to reach
each other on the local network.

From the Mac checkout, run:

```sh
sh scripts/deploy-pi.sh
```

SSH and sudo prompt for the Pi login password. An optional first argument changes
the SSH destination, for example `bret@192.168.2.10`. This stages the current local
backend without needing GitHub credentials on the Pi. It builds for the Pi's ARM64
processor and starts one container with host networking and automatic restart.

The deployment lives in the SSH user's `~/sonos-cd-player` folder. Disc assignments
and CD Sets persist in its `data` folder on the system card, separate from the music
drive. Existing data and `riverside.env` are preserved when deploying again. Copy
the data folder when backing up the server.

The initial environment file configures:

```text
SONOS_SPEAKER_IP=192.168.2.252
SONOS_GROUP_MEMBERS=192.168.2.253
SONOS_UPSTAIRS_IP=192.168.2.254
CHANGER_STATE=/data/changer.json
```

Downstairs is selected by default, with the Amp leading and the Beam joining.
The bedroom Play:1 at `192.168.2.254` is configured separately. Selected rooms join when starting/resuming music, selecting
a disc, changing discs, playing a CD Set, or shuffling discs. Merely loading an
album into the magazine, browsing, polling, pausing, or adjusting volume does not
regroup rooms. Joining preserves the Amp's queue. A failed grouping request stops
the requested music action with an error. If the Amp is already a follower of
another room, the app asks you to make it the coordinator in Sonos rather than
silently replacing its queue. Group the rooms by selecting the Amp first.

Loading or playing a disc or CD Set selects Sonos Repeat All. Tracks and discs
remain in order, and playback returns to the first track after the final disc.

The volume control adjusts the selected leader's current Sonos group while preserving the
relative balance between its members. Upstairs uses the bedroom speaker alone.
TV behavior, including ungrouping on TV autoplay, remains controlled by
the Beam's Sonos settings. The server does not continuously force rooms together.

The default backend behavior without these variables remains Garage at
192.168.1.85 with no automatic grouping.

## Listening areas

`GET /listening-area` returns the saved `area` and the available `areas`, each with
an `id`, display `name`, and configured speaker IPs. This is configuration, not an
online-status check; reading it never changes grouping.

`PUT /listening-area` accepts a JSON body such as `{"area":"upstairs"}`:

| Area | Leader | Other selected speakers |
| --- | --- | --- |
| `downstairs` | Amp, 192.168.2.252 | Beam, 192.168.2.253 |
| `upstairs` | Bedroom Play:1, 192.168.2.254 | None |
| `both` | Amp, 192.168.2.252 | Beam and bedroom |

A change stops current playback, copies the queue when changing leaders, and
preserves loaded CD IDs, order, and saved CD Sets. It selects the beginning of the
current CD (or the first queued track if no CD is current), without starting it.
Press Play afterwards. A repeated selection is a no-op. The destination leader's
existing queue is replaced when switching leaders. The choice persists alongside
the changer state; restarting the server does not regroup rooms or start music.

The backend checks selected speakers before stopping music. An offline ungrouped
bedroom does not prevent ongoing downstairs playback. Switching also needs the
current leader online so its queue can be validated and copied. A failure may
leave playback stopped or grouping partly changed; the selection only changes
after success. The original magazine is retained when its queue can still be
verified. An interrupted or unverified transfer blocks disc operations and Play;
restore the original leader in Sonos, then resync tracking or reload a CD Set.

On an existing Pi deployment, add `SONOS_UPSTAIRS_IP=192.168.2.254` to
`~/sonos-cd-player/riverside.env` before recreating the container with the deployment
script. Existing environment files are intentionally preserved. Reserve the
bedroom's IP in the router and add it to the same Sonos system. Without the new
variable, only Downstairs is offered. The iOS app shows a Listen in selector above
the playback controls on both iPad and iPhone when multiple areas are available.
The selector is hidden for older backends and in demo mode. The new backend
endpoints can also be exercised through `/docs`.

## Verify

In the Pi SSH session:

```sh
curl -fsS http://localhost:8000/
curl -fsS http://localhost:8000/speaker
curl -fsS http://localhost:8000/albums
curl -fsS http://localhost:8000/discs
```

The root endpoint checks the server alone; the other routes require the Amp to be
reachable. Add the `Music` SMB share to S2 and index it before expecting albums.
Use the `music` sharing account in Sonos; no SMB password belongs in the container.
Reserve all speaker IPs and the Pi's IP in the router.

In the iPad app's Connection settings, set the backend to the Pi's IP on port 8000.
The app reads the room name from the backend's `/speaker` endpoint, so its connection
and volume labels follow the selected leader. Actual backend control and relative
album-art paths likewise use that leader.

Validation: backend unit tests cover grouping, unchanged Garage defaults, repeat
play requests, and failure preserving queue/disc state. Physical S2 grouping and
the ARM64 container build must be verified on the Pi during deployment.
