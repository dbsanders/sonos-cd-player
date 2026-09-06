# iOS app

Open SonosCDPlayer.xcodeproj. Select the SonosCDPlayer scheme, your signing team, and an iPhone or simulator, then Run.

The app defaults to http://192.168.1.100:8000. Keep the device on the NAS's local network and allow Local Network access. See the repository root README for backend deployment, API details, and tests.

## iPad interface

Regular-width iPad windows use a vintage hi-fi interface with jewel-case album browsing, brushed-metal panels, an amber status display, a scrollable numbered magazine, transport keys, and volume control. Full-width iPad portrait and landscape layouts place the collection and changer side by side. Narrow iPad windows and iPhones retain the compact tab interface.

Implementation: `SonosCDPlayer/VintageChangerView.swift`. It shares the existing Player network model; no backend deployment is required.

## Loading and track navigation

Pull an unloaded case sideways, then release it over the player. No long press is required. The case follows the pointer or finger and the player highlights while it is a valid destination. A UIKit horizontal pan recognizer yields vertical gestures to collection scrolling. The preview and drop target use live UIKit view coordinates, including in resized iPad windows; scrolling configuration stays stable throughout the gesture. Accepted drops wait for an in-flight status refresh instead of being discarded. Loaded albums are grey with a Loaded badge and cannot be dropped again. VoiceOver offers a Load into magazine action. A successful backend response triggers the disc insertion or ejection animation; Reduce Motion uses a brief fade. Newly loaded discs scroll into view.

Previous/next track controls are distinct from previous/next disc. They require the backend's `/tracks/previous` and `/tracks/next` routes.

Validation: simulator build passed; library loaded-state styling and load/eject actions were checked on a live iPad simulator. Automated simulator drag did not activate the pan through the computer-control tool; the physical iPad gesture still needs verification. Seven backend tests and live track navigation passed.
