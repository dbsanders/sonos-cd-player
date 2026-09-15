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

## CD Sets

On iPad, switch between **CD Library** and **CD Sets** above the collection. Select an album to reveal **Play now** and **Add to CD Set**; adding can append the album to an existing set or create a new single-album set without changing playback. Select a saved set’s artwork card to reveal **Play now** and **Delete this set**, or drag the set to the player to replace the magazine and begin playback. Choose **Save CD Set** on the player to create a new set or select an existing set to overwrite with the currently loaded albums, without interrupting playback. New names must be unique (ignoring case), with 1–80 characters. The iPhone Disc tray retains set playback and deletion in its playback options menu.

Selecting a saved set immediately stops playback and clears the entire Sonos queue, including tracks added outside this app. The backend then resolves and loads the saved albums and starts the first track. **Shuffle CDs when loading** randomizes album order for each selection. **Shuffle Loaded CDs & Play** replaces the current queue with the loaded CDs in random order and restarts playback. Both keep tracks in their library order within each CD and set Sonos playback mode to Normal (track shuffle and repeat off). Shuffling does not change the saved set.

Sets are stored in `/data/cd-sets.json` beside `/data/changer.json`, using album titles and artists rather than queue positions. Both survive backend deployments through the existing data mount. In local development, the sets file is placed beside the configured `CHANGER_STATE` file. Deleting a saved set leaves playback unchanged.

If a load fails after the queue has been cleared, playback is not started and disc tracking is marked incomplete. Choose a set again to replace the partial queue, or reset disc tracking to retain it. Missing albums are not silently skipped or replaced by similarly named albums. Set loading can take longer for large collections; the app allows up to five minutes. If a request times out, refresh to check the result before retrying.

This feature requires both the updated NAS backend (`./scripts/deploy-backend.sh`) and a rebuilt iOS app. Older backends continue to support the existing controls, with CD Sets disabled.

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
| DELETE | `/discs` | Stop playback, clear the entire queue, and remove all CD assignments |
| POST | `/discs/next` or `/discs/previous` | Move between discs with wraparound |
| POST | `/play-album?title=...` | Append and play an album |
| POST | `/play` or `/pause` | Resume or pause |
| POST | `/tracks/next` or `/tracks/previous` | Native Sonos next/previous track |
| GET | `/status` | Track, transport, queue size, volume, mute state |
| GET / POST | `/volume` | Read group volume; set using `?level=0` through `100` |
| POST | `/discs/resync` | Forget disc assignments after external queue edits, keeping tracks |
| GET / POST | `/cd-sets` | List saved sets; save current loaded CDs using `?name=...` |
| POST | `/cd-sets?name=...&title=...&artist=...` | Create a set containing one selected library album |
| POST | `/cd-sets/{id}/albums?title=...&artist=...` | Append a selected library album without changing playback |
| DELETE | `/cd-sets/{id}` | Delete a saved set without changing playback |
| PUT | `/cd-sets/{id}` | Overwrite a saved set with the currently loaded CDs, preserving its name |
| POST | `/cd-sets/{id}/play` | Stop, clear, load, and play a set; optional `?shuffle=true` |
| POST | `/discs/shuffle` | Stop, clear, shuffle loaded CDs, and play from the beginning |

Disc positions are 1-based and inclusive. Existing tracks remain in the queue. External queue edits or partial queue failures produce HTTP 409 until disc mappings are explicitly reset. Avoid simultaneous queue editing from multiple controllers.

## GitHub workflow

Private repository: https://github.com/dbsanders/sonos-cd-player

Clone on another machine:

```sh
git clone git@github.com:dbsanders/sonos-cd-player.git
```

The original checkout tracks `origin/main`. After reviewing and committing changes, publish them with `git push`. Pull updates with `git pull --ff-only`.

Make future iOS and backend changes here and commit them together when appropriate. Open this repository's Xcode project for ongoing work. A compatibility link at `~/Development/SonosCDPlayer` points to the same iOS folder; it is not a second copy.
