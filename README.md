# Sonos CD Player

An iPhone virtual CD changer for the Garage Sonos S1 speaker. A SwiftUI app talks to a FastAPI service on a Synology NAS; the service uses SoCo to play the indexed music library.

## Repository layout

- `ios/SonosCDPlayer/`: Xcode project, Swift source, and app configuration.
- `backend/`: FastAPI service, virtual disc tracking, Docker image, and tests.
- `scripts/`: deploy the backend from this checkout to the NAS.

## Current setup

- NAS/backend: `http://192.168.1.100:8000`
- Speaker: Garage at `192.168.1.85`
- API documentation: `http://192.168.1.100:8000/docs`
- NAS deployment directory: `/volume1/homes/nasadmin/sonos-cd-player`

The app and backend operate on the local network. No credentials belong in this repository. Speaker and NAS addresses are configuration values, not credentials. The current backend has no authentication and should remain on the trusted home network.

## Run the iPhone app

Open `ios/SonosCDPlayer/SonosCDPlayer.xcodeproj` in Xcode. Choose the SonosCDPlayer scheme and your iPhone or a simulator, then Run. Existing signing configuration is preserved; other developers must select their own signing team. Allow Local Network access on the phone. The server address can be changed in the app's Connection settings.

The library shows all 587 currently indexed albums. The app supports loading albums, playing/ejecting discs, next/previous disc, pause/resume, volume, and status refresh.

## Backend development and tests

Use Python 3.13 (the Docker runtime), or a compatible Python 3.12 environment:

```sh
cd backend
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements-dev.txt
pytest
CHANGER_STATE=/tmp/sonos-cd-player-dev.json uvicorn app:app --host 127.0.0.1 --port 8008
```

Tests use a fake speaker and do not play music. Running the development server and issuing control requests operates the real Garage speaker. Use one server worker: the changer synchronizes operations in-process.

## Deploy to the NAS

From the repository root:

```sh
./scripts/deploy-backend.sh
```

This uploads the backend from this checkout using SSH, then requests sudo in your terminal to rebuild/restart the container. It uses `nasadmin@192.168.1.100` by default; an alternative SSH host can be supplied as the first argument. The NAS deployment directory is intentionally fixed to the existing setup.

The restart script builds before stopping the current service, retains the previous container, and rolls back on a failed readiness check. It reuses the existing `data` directory, mounted at `/data`, so disc assignments survive redeployments. Runtime queue state and Docker inspection backups are excluded from Git. Building/pushing Git commits alone does not deploy anything.

Verify deployment using `/discs`, `/status`, and `/albums`. The container uses host networking to reach Sonos. Keep the NAS's music share and Sonos music-library setup unchanged.

## API overview

| Method | Path | Action |
|---|---|---|
| GET | `/albums` | Complete indexed album library |
| GET | `/discs` | Disc list and current disc |
| POST | `/discs/load?title=...&artist=...` | Append an album without playing |
| POST | `/discs/{id}/play` | Start a disc |
| DELETE | `/discs/{id}` | Eject a disc |
| POST | `/discs/next` or `/discs/previous` | Move between discs with wraparound |
| POST | `/play-album?title=...` | Append and play an album |
| POST | `/play` or `/pause` | Resume or pause |
| POST | `/tracks/next` or `/tracks/previous` | Native Sonos next/previous track |
| GET | `/status` | Track, transport, queue size, volume, mute state |
| GET / POST | `/volume` | Read volume; set using `?level=0` through `100` |
| POST | `/discs/resync` | Forget disc assignments after external queue edits, keeping tracks |

Disc positions are 1-based and inclusive. Existing tracks remain in the queue. External queue edits or partial queue failures produce HTTP 409 until disc mappings are explicitly reset. Avoid simultaneous queue editing from multiple controllers.

## GitHub workflow

Private repository: https://github.com/dbsanders/sonos-cd-player

Clone on another machine:

```sh
git clone git@github.com:dbsanders/sonos-cd-player.git
```

The original checkout tracks `origin/main`. After reviewing and committing changes, publish them with `git push`. Pull updates with `git pull --ff-only`.

Make future iOS and backend changes here and commit them together when appropriate. Open this repository's Xcode project for ongoing work. A compatibility link at `~/Development/SonosCDPlayer` points to the same iOS folder; it is not a second copy.
