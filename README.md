# BPM: Bullets Per Minute — Archipelago Integration

Archipelago multiworld integration for **BPM: Bullets Per Minute**, built as a UE4SS Lua mod with a small standalone Python client and an IPC bridge between BPM and Archipelago.

> **Current release: v1.5.0 — First Real Patch**
>
> The first production patch is focused on the core bridge plus the gameplay events that have been verified in BPM: coins, Treasure rewards, and Challenge rewards. Startup stability/crash investigation is intentionally a separate follow-up phase.
>
> This version is only tested for Windows x64 architecture.
> Future versions will be tested on steam deck and linux architectures, but remain questionable due to the need of implementing UE4SS which is Windows-only.

## Current Status

### v1.5.0 first real patch

The current production patch includes:

- Direct BPM → Archipelago location checks through the IPC bridge.
- 10 individual coin checks.
- Coin milestones at 5, 10, and 25 coins.
- **10 Treasure reward checks.**
  - Locked chests have been verified to enter BPM's Treasure reward path, so they are treated as Treasure locations.
- **10 Challenge reward checks.**
- Automatic incoming Archipelago item delivery through confirmed game-event hooks.
- Persistent per-session coin/reward progress.
- Persistent processed-item tracking so received AP items are not granted twice.
- Archipelago Victory delivery through the existing `GOAL` IPC message.
- Existing verified key/stat/shield item grants and Health Container handling retained from the diagnostic builds.

The production patch does **not** currently use `TrySpawnRewards`; testing showed that it was not the relevant trigger for the reward interactions being tracked.

`Movement Boost` is not included as an AP item.

## Verified BPM Reward Events

The following BPM functions have been verified with live UE4SS `RegisterHook` callbacks:

```text
/Script/BPM.BPMGameInstance:ConsumeAndReturnRandomTreasureItem
/Script/BPM.BPMGameInstance:ConsumeAndReturnRandomChallengeItem
```

A locked chest was also verified to reach the Treasure function, which provides the runtime event needed for the planned Treasure/chest AP locations.

The following was tested but is **not** used by the production reward system:

```text
/Script/BPM.BPMRoomScriptActor:TrySpawnRewards
```

It did not fire during the relevant reward tests.

## Health Behavior

BPM's `GiveHealth(25)` function was verified through UE4SS, but it does not reproduce the normal pickup behavior we want for an Archipelago Health item: a test at 50/100 HP produced 100/100 HP.

Therefore the production patch does not use `GiveHealth(25)` as the final implementation of an AP Health pickup.

The intended future behavior is:

```text
current HP + 25, capped at maximum HP
```

For example:

```text
50/100  -> 75/100
90/100  -> 100/100
```

A future patch will add a safe implementation once the correct underlying BPM health-setting path has been identified.

## Archipelago World

The matching v1.5.0 APWorld adds the production Treasure and Challenge reward locations to the existing BPM location pool.

The first patch uses:

- 10 Treasure locations.
- 10 Challenge Reward locations.
- The existing coin, room, key, stat, item, weapon, boss, altar, floor, and goal catalog already present in the project.
- Nidhogg remains the Victory/goal event.

The Lua mod and APWorld should be kept at the same release version.

## Installation

### 1. UE4SS

BPM testing currently uses the Windows version of BPM with UE4SS.

Install UE4SS in BPM's `Binaries/Win64` directory using the appropriate UE4SS build for the game.

The mod is enabled through `mods.txt` with:

```text
BPMArchipelago : 1
```

The project also depends on the UE4SS console/keybind functionality already used during development.

### 2. BPM Mod Files

Place the production Lua file as:

```text
BPM/
└── Binaries/
    └── Win64/
        └── Mods/
            └── BPMArchipelago/
                ├── main.lua
                └── IPC/
```

The Lua script automatically uses the sibling `IPC` directory for communication files.

### 3. Archipelago World

Install:

```text
bpm_bullets_per_minute_v1.5.0.apworld
```

in the appropriate Archipelago custom-world directory.

The `.apworld` contains the BPM locations/items used by the v1.5.0 Lua runtime.

### 4. Standalone BPM Client

The standalone Python client connects BPM's IPC directory to an Archipelago server.

The launch format used by the current client is:

```text
run_bpm_client.bat HOST:PORT SLOT PASSWORD "IPC_PATH"
```

The client writes incoming Archipelago items to `incoming.txt` and reads BPM checks/reward acknowledgements from `outgoing.txt`.

## IPC Files

The main bridge files are:

```text
IPC/
├── incoming.txt
├── outgoing.txt
├── client_status.txt
├── ap_connected.flag
├── delivered_items.txt
├── processed_items.txt
├── coin_state.txt
└── reward_state.txt
```

The Python client persists delivered Archipelago item indices in `delivered_items.txt`.

The Lua mod persists processed BPM-side item indices in `processed_items.txt` and session-scoped location progress in the state files.

## Useful In-Game Commands

The production build keeps the main operational diagnostics rather than the large discovery/debugging suite.

```text
BPMAP_STATUS
BPMAP_AP_STATUS
BPMAP_PATH
BPMAP_HOOKS
BPMAP_PROCESS_ITEMS
BPMAP_AUTO_ITEMS
BPMAP_AUTO_LAST
BPMAP_REGISTERHOOK_STATUS
BPMAP_REWARD_STATUS
BPMAP_COIN_STATUS
BPMAP_COIN_SESSION
```

The manual location-check command remains available:

```text
BPMAP_CHECK <location_id>
```

## Current Automatic Item Delivery Design

Automatic AP item delivery is **event-driven**.

The project previously tested UE4SS delayed actions, game-thread timers, tick hooks, and custom event approaches. Those approaches were not reliable in the current BPM/UE4SS configuration, so the production runtime uses confirmed `RegisterHook` callbacks instead.

Only one queued AP item is processed per trigger, with re-entry protection to prevent an AP grant from immediately recursively processing another item.

This design avoids the unavailable delayed-action mode and keeps the automatic delivery path on confirmed BPM gameplay callbacks.

## Development History

The project progressed through several diagnostic builds before the first production patch.

Important verified milestones included:

1. Direct BPM location checks reaching Archipelago.
2. Archipelago → BPM incoming item transport working through the standalone client and IPC directory.
3. Manual AP item receipt working.
4. Automatic AP item processing working through confirmed `RegisterHook` gameplay events.
5. Verified numeric reward/stat functions for keys, damage, critical, range, movement speed, luck, extra ammo, ability power, health containers, and shield.
6. Verified Treasure and Challenge reward event functions.
7. Verification that locked chests use the Treasure reward path.
8. v1.5.0 — first production patch.

## Known Issues / Next Development Phase

### Startup stability

The largest remaining issue is that BPM may crash repeatedly during startup/new-run initialization before eventually launching successfully. The project will investigate this separately from the now-established reward/check architecture.

The next stability work should prioritize identifying which hook or initialization behavior contributes to those crashes without changing the already verified Treasure/Challenge reward logic.

### Additional location checks

More automatic checks will be added after the startup behavior is understood. Candidate areas include additional room/floor/boss/altar/item/weapon events and other reward mechanics discovered during diagnostics.

### Health item

The final AP Health implementation still needs a native BPM path that reproduces the game's observed +25-or-to-max pickup behavior rather than the full-heal behavior of `GiveHealth(25)`.

## Repository Development Notes

The project is intended to be developed incrementally:

```text
Confirmed runtime behavior
        ↓
Targeted diagnostic hook
        ↓
Live verification in BPM
        ↓
Production Lua/APWorld update
        ↓
Stability testing
        ↓
Additional location expansion
```

Large object/function discovery scans are manual development tools only and should not be run automatically during normal gameplay.

High-frequency gameplay callbacks should remain lightweight and should not perform broad UObject scans or unnecessary filesystem work.

## Credits / Dependencies

This project depends on:

- [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) for Unreal Engine mod loading, Lua scripting, reflection, and function hooks.
- [Archipelago](https://archipelago.gg/) for multiworld generation and network communication.

## License

See the repository's license file for project-specific licensing information.
