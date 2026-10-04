# TF3 Subsidy Manager: Investigation and Proof of Concept

This repository contains a small, read-only Transport Fever 3 mod proof of concept. It adds a native-style Subsidies button, opens a movable game window, and reads the subsidy lists already attached to a game-script component. It does not accept, decline, edit, or otherwise change subsidies.

## Phase 1: Investigation

### Confirmed API

- TF3 mods are directories with a `mod.json` manifest and resource files. The installed game includes Teal definitions and shipped mods; the official manual's [introduction](https://wiki.transportfever3.com/doku.php?id=modding:introduction) says mods are directory-based and warns against editing installation files.
- The official [scripting reference](https://wiki.transportfever3.com/script-doc/) documents `api.engine` as read-only access to the engine state from both GUI and engine script states. It exposes `forEachEntityWithComponent`, `getComponent`, `ComponentType.GAME_SCRIPT`, and `Engine.Component.GameScript<T>.state`.
- TF3's public engine API exposes `api.engine.system.gameScriptSystem.getEntityForGameScript(name)`. The POC instead enumerates game-script components and identifies the subsidy state by its typed fields, so it does not need to guess the built-in script's resource name.
- The installed base type file `base/tealdef/game_mechanics/subventions/subvention.d.tl` defines `SubventionState` with `proposedSubventions`, `activeSubventions`, `completedSubventions`, and `failedSubventions`. A subsidy record includes status and timestamps; its data includes name, expiry durations, required quantity, delivered quantity, and upfront/completion/failure effects. Effects can be Money, Reputation, or TownExperience.
- The built-in UI types also define card data for description, deadline, progress, locations, cargo icons, and effects. A current community mod, [TF3 Minimap](https://github.com/schbrongx/tf3mod-minimap), demonstrates a bottom mod-button-area plugin, `builtin.Window`, a `ModEntryPointExtension`, and the current React GUI resource layout.
- `api.gui.game.getGuiSaveData(modId)` and `setGuiSaveData(modId, data)` are documented. They are suitable for mod-owned GUI preferences persisted with a save. The game's own script state is also part of save state.
- `api.gui.camera.focusEntity` and `focusPosition` are documented, so camera focus is possible when a relevant entity or position is available.

### Not Exposed or Uncertain

- The subsidy records and their lifecycle implementation are in `base/tealdef`, not in the public `api/tealdef` package. The engine accessor is officially read-only, but subsidy field names are base-game contracts and could change between game updates. The mod therefore guards for missing state and performs no writes.
- The base subsidy type declares lifecycle callbacks (`onAccept`, `onUpdate`, `onComplete`, `onFailure`), but there is no documented external-mod subscription hook for those callbacks. This POC uses an explicit Refresh control rather than adding a polling loop.
- The state shape has completed and failed collections, but the shipped type declarations alone do not establish how long those collections are retained. The POC displays records still present in those lists; long-term history retention needs in-game verification across completion, failure, save/reload, and multiple versions.
- The POC does not infer missing rewards, locations, or failure reasons. A later implementation can use the base `SubventionCardData` helpers if their use from external GUI mods is validated in-game.
- No supported direct-acceptance API was found. There is no acceptance action in this POC; use the game's normal subsidy interface.
- The bottom-bar plugin extension point is demonstrated by a working community mod, but the official manual does not document the React plugin extension system in detail. It depends on TF3's shipped GUI modules and should be rechecked after game updates.

## Proof of Concept

The three tabs display in-progress, offered, and history records from the game's current subsidy state. Each row shows the subsidy name and transported/required count. Use Refresh to reread state. Empty and unavailable states are explicit. No synthetic subsidy examples are generated.

The mod only reads engine component state. The button and window do not issue simulation commands or write subsidy data. Debug logging is off by default; set `DEBUG_LOGGING` to `true` in `content/plugins/subsidy_manager/main.script.tl` during development.

## Installation

This mod can be installed manually without changing any Transport Fever 3 game files. Copy the entire `mod/tf3_subsidy_manager_1` folder from this repository into the `mods` folder for your TF3 user data. For the Steam/Linux setup used during development, the destination is:

```text
~/.local/share/Steam/userdata/7253637/3493540/local/mods/
```

If the `mods` folder does not exist, create it. After copying, verify the manifest is at `.../local/mods/tf3_subsidy_manager_1/mod.json` (not in an extra nested `tf3_subsidy_manager_1` folder). Restart TF3, enable **Subsidy Manager (Proof of Concept)** in the mod list for a save, then load the save.

For another Steam account or platform, use that account's TF3 user-data `mods` directory; the Steam account ID and Steam library location may differ. Do not copy the mod into the game installation directory. TF3's mod browser uses mod.io; this source directory can also be packaged and shared manually.

## Removal

Disable the mod in the save's mod list, exit the game, and remove the `tf3_subsidy_manager_1` directory from the user-data `mods` directory. This POC stores no custom simulation or subsidy state, so removing it cannot remove or corrupt subsidy records.

## Development Checks

The game compiles `.tl` scripts when loading mods. For editor-side type checking, set `TF3_INSTALL_DIR` to the TF3 install directory and use the included `tlconfig.lua` with Teal (`tl`). The `.res.lua` files can be checked with `luac -p`.

An in-game verification still needs to confirm mod loading, button/window visibility, and state reads in a save containing subsidies. If the window reports that no readable subsidy state was found, retain that exact save/log result before broadening the field matching.