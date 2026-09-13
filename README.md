# BPM: Bullets Per Minute — Archipelago

A community Archipelago implementation for **BPM: Bullets Per Minute**.

This project connects BPM to the [Archipelago Multiworld Randomizer](https://archipelago.gg/), allowing BPM checks and items to participate in an Archipelago multiworld.

> **Current status:** Windows support
> **Current release:** v1.0.1 MVP

---

## Features

The current MVP includes:

* 14 Room Clear checks
* 10 individual Coin checks
* 3 cumulative Coin milestone checks

  * Collect 5 Coins
  * Collect 10 Coins
  * Collect 25 Coins
* Defeat Nidhogg goal
* Archipelago item delivery
* Coins
* Keys
* Health Containers
* Weapon damage upgrades
* Critical upgrades
* Range upgrades
* Movement Speed upgrades
* Luck upgrades
* Extra Ammo upgrades
* Ability Power upgrades
* Movement Boost
* Archipelago session-aware item synchronization
* Automatic reconnect/index synchronization through the companion client

---

## Requirements

### Game

A Windows installation of:

**BPM: Bullets Per Minute**

The game must be installed through Steam.

### Archipelago

An Archipelago installation capable of loading custom `.apworld` files.

Download Archipelago from:

https://archipelago.gg/

### Mod Loader

This project currently uses **UE4SS** to load the BPM Lua mod.

### Windows

The current release has been tested on Windows.

Linux, Steam Deck, and other platforms are not currently supported.

---

# Installation

## 1. Install Archipelago

Install the current Archipelago release on your computer.

After installation, locate your Archipelago installation directory.

You will need access to the Archipelago `lib/worlds` directory if you wish to manually install.

---

## 2. Manually Install the BPM `.apworld`

Download the BPM `.apworld` release from the project's Releases page.

Copy the `.apworld` file into:

```text
<Archipelago installation>\lib\worlds\
```

For example:

```text
C:\ProgramData\Archipelago\lib\worlds\
```

or wherever your Archipelago installation is located.

Do not extract the `.apworld` file.

It should remain a single `.apworld` file.

---

## 2B. Auto Install the BPM `.apworld`

Download the BPM `.apworld` release from the project's Releases page.

Load up the archipelago application and navigate to `Install APWorld`

Click `Open` and navigate to your `.apworld` installation location.

Select the `.apworld` and relaunch the archipelago application.


## 3. Install UE4SS

Install UE4SS for BPM according to the UE4SS installation instructions.

The game should contain the UE4SS files in the appropriate BPM installation directory.

Your BPM installation should ultimately contain a structure similar to:

```text
BPM BULLETS PER MINUTE\
└── Windows NoEditor\
    └── BPM\
        └── Binaries\
            └── Win64\
                └── Mods\
```

---

## 4. Install BPMArchipelago

Copy the `BPMArchipelago` mod into the game's UE4SS Mods directory.

The final structure should look similar to:

```text
BPM\
└── Binaries\
    └── Win64\
        └── Mods\
            └── BPMArchipelago\
                ├── IPC\
                └── scripts\
                    └── main.lua
```

The exact location may differ depending on your Steam installation.

For a default installation, the important part is that:

```text
BPMArchipelago
```

is inside:

```text
Binaries\Win64\Mods\
```

---

## 5. Enable the mod

Open the UE4SS `mods.txt` file.

Add or enable:

```text
BPMArchipelago : 1
```

The relevant section should look similar to:

```text
ConsoleCommandsMod : 1
ConsoleEnablerMod : 1
BPModLoaderMod : 1
BPML_GenericFunctions : 1
BPMArchipelago : 1
```

Save the file.

---

# Running the Archipelago Client

The BPM mod communicates with Archipelago through the included standalone client.

The client handles:

* Archipelago server connection
* Receiving items
* Sending location checks
* Archipelago session tracking
* Synchronizing received-item indexes
* Communication with the BPM Lua mod

Start the client using the provided Windows launcher.

The launcher is:

```text
run_bpm_client.bat
```

The expected command format is:

```text
run_bpm_client.bat HOST:PORT SLOT PASSWORD "IPC"
```

Example:

```text
run_bpm_client.bat archipelago.gg:61945 PlayerName "" "D:\SteamLibrary\steamapps\common\BPM BULLETS PER MINUTE\Windows NoEditor\BPM\Binaries\Win64\Mods\BPMArchipelago\IPC"
```

The exact host, port, slot name, and password depend on the Archipelago game session.

---

# Connecting to a Game

A typical setup is:

```text
Archipelago Server
       │
       │ WebSocket
       ▼
BPM Archipelago Client
       │
       │ IPC files
       ▼
BPMArchipelago UE4SS Mod
       │
       ▼
BPM: Bullets Per Minute
```

The BPM client and game mod use the `IPC` directory to exchange data.

---

# Archipelago Items

The current release supports the following received items:

| Item              | Effect                        |
| ----------------- | ----------------------------- |
| Coins +5          | Adds 5 coins                  |
| Coins +10         | Adds 10 coins                 |
| Keys +1           | Adds 1 key                    |
| Keys +5           | Adds 5 keys                   |
| Health Container  | Adds a health container       |
| Damage Up         | Adds 1 weapon damage upgrade  |
| Critical Up       | Adds 1 critical upgrade       |
| Range Up          | Adds 1 range upgrade          |
| Movement Speed Up | Adds 1 movement speed upgrade |
| Luck Up           | Adds 1 luck upgrade           |
| Extra Ammo Up     | Adds 1 extra ammo upgrade     |
| Ability Power Up  | Adds 1 ability power upgrade  |
| Movement Boost    | Adds 1 movement boost         |
| Damage Up +2      | Adds 2 weapon damage upgrades |

Victory is handled as an Archipelago goal event rather than a normal player inventory item.

---

# Location Checks

The current MVP contains:

### Room Clears

```text
Room Clear 01
Room Clear 02
Room Clear 03
Room Clear 04
Room Clear 05
Room Clear 06
Room Clear 07
Room Clear 08
Room Clear 09
Room Clear 10
Room Clear 11
Room Clear 12
Room Clear 13
Room Clear 14
```

### Individual Coins

```text
Coin 001
Coin 002
Coin 003
Coin 004
Coin 005
Coin 006
Coin 007
Coin 008
Coin 009
Coin 010
```

### Coin Milestones

```text
Collect 5 Coins
Collect 10 Coins
Collect 25 Coins
```

### Goal

```text
Defeat Nidhogg
```

---

# Coin Checks

The first ten coin pickups in an Archipelago session generate individual checks:

```text
Coin #1  → Coin 001
Coin #2  → Coin 002
Coin #3  → Coin 003
...
Coin #10 → Coin 010
```

Coin milestones are tracked separately.

For example:

```text
5th coin
 ├── Coin 005
 └── Collect 5 Coins

10th coin
 ├── Coin 010
 └── Collect 10 Coins

25th coin
 └── Collect 25 Coins
```

After `Coin 010`, additional coins no longer generate individual Coin locations, but the cumulative milestone counter continues toward `Collect 25 Coins`.

---

# Important MVP Note

Individual Coin locations currently use **pickup order** rather than a permanent identity for each physical coin actor.

That means:

```text
first tracked pickup  = Coin 001
second tracked pickup = Coin 002
...
```

Coin progress is associated with the active Archipelago session so that restarting the game/mod does not intentionally create a new sequence within the same session.

A future release may replace pickup-order tracking with persistent physical coin identities if a reliable method can be established.

---

# Useful Debug Commands

The BPMArchipelago mod provides several console commands for testing and diagnostics.

## Bridge status

```text
BPMAP_STATUS
```

## IPC path

```text
BPMAP_PATH
```

## Archipelago status

```text
BPMAP_AP_STATUS
```

or:

```text
AP_STATUS
```

## Coin status

```text
BPMAP_COIN_STATUS
```

## Install coin pickup checking

```text
BPMAP_COIN_CHECK
```

## Synchronize coin session

```text
BPMAP_COIN_SESSION
```

## Reset local coin tracking

```text
BPMAP_COIN_RESET
```

> `BPMAP_COIN_RESET` only resets the local Lua tracking state.
> It does **not** undo checks already sent to the Archipelago server.

---

# Manually Testing Location Checks

Any known BPM location can be queued manually.

Example:

```text
BPMAP_CHECK 11993103
```

That queues:

```text
Coin 001
```

You can also use the more convenient coin command:

```text
BPMAP_CHECK_COIN 1
```

For example:

```text
BPMAP_CHECK_COIN 10
```

queues `Coin 010`.

Milestones can be tested with:

```text
BPMAP_CHECK_MILESTONE 5
BPMAP_CHECK_MILESTONE 10
BPMAP_CHECK_MILESTONE 25
```

Room checks can be tested with:

```text
BPMAP_CHECK_ROOM 1
BPMAP_CHECK_ROOM 14
```

The Nidhogg goal can be tested with:

```text
BPMAP_CHECK_BOSS
```

---

# Manual Item Processing

Received Archipelago items are intentionally processed manually in the current MVP to avoid performing filesystem work on the game's frame/tick path.

Run:

```text
BPMAP_PROCESS_ITEMS
```

The command processes the queued items in the BPM IPC directory.

This design is intentional for the current release.

---

# Troubleshooting

## The game does not recognize BPMAP commands

Check that:

```text
BPMArchipelago : 1
```

is enabled in `mods.txt`.

Also verify that UE4SS and the required UE4SS support mods are installed.

---

## The client connects but the game does not receive items

Check:

```text
BPMAP_PATH
```

Make sure the reported IPC directory is the same directory being used by the standalone BPM Archipelago client.

Then run:

```text
BPMAP_PROCESS_ITEMS
```

---

## A received item is not being granted

Check the BPM IPC directory for:

```text
incoming.txt
processed_items.txt
outgoing.txt
call_tests.txt
```

Then run:

```text
BPMAP_PROCESS_ITEMS
```

The console result should indicate whether the item was granted or whether the player/function lookup failed.

---

## Coin checks are not being sent

Run:

```text
BPMAP_COIN_CHECK
```

Then:

```text
BPMAP_COIN_STATUS
```

The status should report:

```text
installed=true
```

After picking up a coin, run:

```text
BPMAP_COIN_STATUS
```

The callback counter should increase.

---

# Current Release

## v1.0.1 — MVP

The first MVP content release includes:

* 14 Room Clear locations
* 10 individual Coin locations
* 3 Coin milestone locations
* Nidhogg goal
* Current supported BPM item set
* Stable Archipelago client communication
* Session-aware received-item handling
* Windows support

Existing location IDs from earlier releases are preserved for compatibility.

---

# Development Status

This project is actively being developed.

The current MVP focuses on establishing a reliable Archipelago gameplay loop before expanding the location and item set.

Planned future work may include:

* More BPM location checks
* More item types
* Improved persistent coin identity
* Additional room/event logic
* Expanded boss checks
* Improved non-Windows support
* Additional quality-of-life tooling

---

# Project Structure

The repository is organized around three main components:

```text
BPM Archipelago
│
├── APWorld
│   ├── __init__.py
│   ├── items.py
│   ├── locations.py
│   ├── archipelago.json
│   └── README.md
│
├── BPMArchipelago
│   ├── scripts/
│   │   └── main.lua
│   └── IPC/
│
└── BPM Client
    ├── BPMClientStandalone.py
    └── run_bpm_client.bat
```

---

# Credits

Created by **S3ven_Six**.

BPM: Bullets Per Minute is developed by Awe Interactive.

Archipelago is an open-source multiworld randomizer platform.

This project is a community-made integration and is not affiliated with Awe Interactive or the official Archipelago project.
