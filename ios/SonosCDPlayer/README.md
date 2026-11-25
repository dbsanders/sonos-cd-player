# iOS app

Open SonosCDPlayer.xcodeproj. Select the SonosCDPlayer scheme, your signing team, and an iPhone or simulator, then Run.

The same target supports Mac Catalyst on macOS 14 or newer. An Intel test build
uses the generic Mac Catalyst destination with `ARCHS=x86_64`; it shares the
same Connection setting as the iPhone and iPad versions.

The app defaults to http://192.168.1.100:8000. Keep the device on the NAS's local network and allow Local Network access. See the repository root README for backend deployment, API details, and tests.

If an iPad reports that the internet is offline, enable **Settings → Privacy & Security → Local Network → CD Player** and return to the app. The app needs local access to the NAS; internet access alone is insufficient. Open `http://192.168.1.100:8000/docs` in Safari on the iPad to check whether it can reach the backend. If that fails too, check the Wi-Fi network, VPN routing, NAS address, and backend service. Confirm the address in the app’s Connection settings.

API requests wait up to 30 seconds for connectivity, including the initial permission prompt. Background refresh retries an unsuccessful initial library load after connectivity returns.

While the app is active, status refreshes run in the background every five seconds
without dimming the buttons or flashing a progress indicator. Controls show busy
state for manual refreshes and user actions. An action requested during a
background refresh waits for that refresh to finish before sending its command.
Rebuild and install the app to receive this fix; no backend update is needed.

## iPad interface

Regular-width iPad windows use a vintage hi-fi interface with jewel-case album browsing, flat dark panels, an amber status display, a scrollable numbered magazine, transport keys, and volume control. Full-width iPad portrait and landscape layouts place the collection and changer side by side. Narrow iPad windows and iPhones retain the compact tab interface.

Implementation: `SonosCDPlayer/VintageChangerView.swift`. It shares the existing Player network model; no backend deployment is required.

## Listening areas

The iPhone Now Playing screen scrolls and uses a compact navigation title and
disc image to keep the volume control reachable above the tab bar, including
when room selection is visible or larger text needs more space. Rebuild and
install the iOS app to receive this layout fix.

With the updated Riverside backend, **Listen in** above the playback controls
offers **Downstairs**, **Upstairs**, and **Both** on iPad and iPhone. Changing rooms
stops music and preserves loaded CDs; press Play to restart the selected CD.
Volume and the room label follow the selected area. The choice is saved on the
backend and shared by every device. The control shows progress during a switch
and refreshes the actual selection if a request fails or times out.

Both layouts use a shared UIKit volume slider that releases the volume-editing
lock when a touch ends or is cancelled. This prevents listening-area selection
and background refresh from remaining disabled after adjusting volume. Install
a rebuilt iOS app to receive this fix; no backend update is needed.

Older backends, single-area installations, and demo mode hide the selector and
retain the existing controls. Riverside's backend address is
`http://192.168.2.100:8000`; existing saved app addresses are preserved.

## CD Sets

Use the **CD Library** and **CD Sets** buttons at the top of the iPad collection to switch views. Saved sets show artwork from an album in the set (or a disc placeholder if artwork is unavailable). Select a card to reveal **Play now** and **Delete this set**, or drag the card sideways to the player. Play now and a successful drop replace the entire queue with the set and start playback; deleting a set leaves playback unchanged.

Choose **Save CD Set** on the player to create a named set or select an existing set to overwrite with the current magazine. Overwrite preserves the set’s name and does not interrupt playback. The separate shuffle menu retains **Shuffle CDs when loading** and **Shuffle Loaded CDs & Play**. The iPhone tray also has Save CD Set, with saved-set playback and deletion in its playback options menu.

Sets are shared through the NAS. Overwriting requires the updated backend’s `PUT /cd-sets/{id}` endpoint; deploy the backend and rebuild the app.

## Library sorting

The **Sort by** selector orders the library by **Artist** or **Album name**, including search results. Artist sorting uses album name to break ties; album sorting uses artist. The selection is remembered and shared between the iPad and compact layouts on the device.

## Loading and track navigation

Tap a library case to select it and reveal **Play now** and **Add to CD Set**. Add to CD Set appends the album to an existing set or creates a new set containing that album without changing playback or the loaded magazine. Only pressing **Play now** starts playback, loading the CD first if needed; an already-loaded CD plays without adding a duplicate. Selecting another case moves the selection. VoiceOver exposes the same actions. Dragging still loads without starting playback.

Pull an unloaded case sideways, then release it over the player. No long press is required. The case follows the pointer or finger and the player highlights while it is a valid destination. A UIKit horizontal pan recognizer yields vertical gestures to collection scrolling. The preview and drop target use live UIKit view coordinates, including in resized iPad windows; scrolling configuration stays stable throughout the gesture. Accepted drops wait for an in-flight status refresh instead of being discarded. Loaded albums are grey with a Loaded badge and cannot be dropped again. VoiceOver offers a Load into magazine action. A successful backend response triggers the disc insertion or ejection animation; Reduce Motion uses a brief fade. Newly loaded discs scroll into view.

To unload a disc, pull its title sideways from the magazine and release anywhere over the collection. The case follows your finger, the source dims, and the collection highlights with “Release to unload disc.” Releasing outside the collection or cancelling the drag leaves the disc loaded. Tapping the title still plays the disc; the eject button and VoiceOver “Unload to collection” action are also available. Unloading uses the existing eject API and waits for any in-flight request before checking that the disc is still loaded.

The **Eject all** button above the magazine’s eject buttons stops playback and clears the entire Sonos queue in one bulk operation, including any tracks added outside the app, then removes all CD assignments. It is disabled while the magazine is empty, busy, being dragged, or needs resync. Deploy the updated backend before using this feature; it requires `DELETE /discs`.

Previous/next track controls are distinct from previous/next disc. They require the backend's `/tracks/previous` and `/tracks/next` routes.

Validation: simulator build passed; library loaded-state styling and load/eject actions were checked on a live iPad simulator. Automated simulator drag did not activate the pan through the computer-control tool; the physical iPad gesture still needs verification. Seven backend tests and live track navigation passed.
