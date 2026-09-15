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
CHANGER_STATE=/data/changer.json
```

The Amp leads the group. The Playbar joins when starting/resuming music, selecting
a disc, changing discs, playing a CD Set, or shuffling discs. Merely loading an
album into the magazine, browsing, polling, pausing, or adjusting volume does not
regroup rooms. Joining preserves the Amp's queue. A failed grouping request stops
the requested music action with an error. If the Amp is already a follower of
another room, the app asks you to make it the coordinator in Sonos rather than
silently replacing its queue. Group the rooms by selecting the Amp first.

The volume control adjusts the Amp's current Sonos group while preserving the
relative balance between its members. When the Amp is not grouped, it adjusts the
Amp alone. TV behavior, including ungrouping on TV autoplay, remains controlled by
the Playbar's Sonos settings. The server does not continuously force rooms together.

The default backend behavior without these variables remains Garage at
192.168.1.85 with no automatic grouping.

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
Reserve both speaker IPs and the Pi's IP in the router.

In the iPad app's Connection settings, set the backend to the Pi's IP on port 8000.
The app reads the room name from the backend's `/speaker` endpoint, so its connection
and volume labels follow the configured Amp. Actual backend control likewise uses
the configured Amp. Relative album-art paths returned by Sonos are resolved against
that Amp as well, rather than an address belonging to another installation.

Validation: backend unit tests cover grouping, unchanged Garage defaults, repeat
play requests, and failure preserving queue/disc state. Physical S2 grouping and
the ARM64 container build must be verified on the Pi during deployment.
