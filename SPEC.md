# Poolside: an iOS replacement for the Pentair ScreenLogic app

Personal-use app. Not for distribution. Built from Greg's Android brief (Oct 27) and Jonathan's notes: own design, and it has to work on home WiFi and away from home.

## What it does

1. Sign in with the system name (the "Pentair: XX-XX-XX" name, what Greg's brief called the "protocol") and the remote access password (the "pin"/"code").
2. Connection: Auto (default), Local only, or Remote only.
   - Auto tries the gateway on your WiFi first, then falls back to Pentair's remote server.
   - Stays signed in until you tap Sign out. Password lives in the Keychain.
3. Pool and spa: water temp, on/off, heat on/off, heat mode, set the target temp.
4. Features: every auxiliary circuit (cleaner, blower, water feature, pump speeds) as a one-tap toggle.
5. Lights: individual lights on/off, all on/all off, and the IntelliBrite color scenes.
6. One home screen with all of it. Heat opens as a sheet.
7. Target temp uses a scroll wheel, not +/- (the one fix Greg's build needed).

## How it talks to the pool

ScreenLogic protocol, as reverse-engineered by node-screenlogic (MIT) and screenlogicpy (GPL-3.0).

- Local: find the gateway with a UDP probe on port 1444, open TCP to it (usually port 80), send `CONNECTSERVERHOST`, ask for the challenge (the adapter's MAC), log in.
- Remote: ask `screenlogicserver.pentair.com:500` where the system is (msg 18003), then connect to the address it returns and log in with the password AES-encrypted against the challenge.
- Every message: 8-byte header (uint16 sender, uint16 message id, uint32 length), little-endian payload, strings padded to 4 bytes.
- Reads: controller config (12532) for names, circuit types and setpoint limits; equipment state (12526) for temps, heat and circuit states. Polled every few seconds while the app is open.
- Writes: circuit on/off (12530), setpoint (12528), heat mode (12538), light command (12556).
- Schedules: read (12542, recurring and run-once), add an empty slot (12544), fill or change it (12548), delete (12546). Schedule ids are 700 and up and circuit ids are the config's raw ids, sent back as-is. Days are a bitmask, bit 0 Monday to bit 6 Sunday. On and off one minute apart (8:00 to 7:59) means all day.

## iOS specifics

- Needs the Local Network permission prompt (Info.plist key is set).
- iOS blocks UDP broadcast unless Apple grants the multicast entitlement. So discovery tries broadcast, then sends the probe to each address on your subnet one by one, and you can always type the gateway's IP.
- Remote needs the remote access password set in the official app or on the adapter.
- Sideloaded with a free Apple ID the app expires after 7 days; a paid developer account ($99/yr) keeps it for a year.

## Design

Original, not a copy of the Android build. Native SwiftUI, light and dark.
- Header: system name, connection pill (Local or Remote), air temp.
- Pool and spa as two side-by-side tiles with the big temp and a flame when heating. Tap opens the heat sheet.
- Features as a Control Center style tile grid.
- Lights as a scene strip plus tiles.

## Later

- Siri and Shortcuts ("turn on the spa") via App Intents.
- Home Screen widget with water temps.
- Push updates (add client, msg 12522) instead of polling.
- Chemistry and pump readouts.
- Heat settings inside schedules (the controller stores a heat command and setpoint per schedule; the app keeps whatever is there).
