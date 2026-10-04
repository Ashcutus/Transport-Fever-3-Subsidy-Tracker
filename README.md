# TF3 Subsidy Manager — v0.1 Native UI

This repository contains a small, read-only Transport Fever 3 mod proof of concept. It adds a small Subsidy Manager button beside Industry Statistics in the bottom-right toolbar, opens a movable game window, and consolidates the subsidy lists already attached to a game-script component. It does not accept, decline, edit, or otherwise change subsidies.

## Phase 1: Investigation

### Confirmed API

- TF3 mods are directories with a `mod.json` manifest and resource files. The installed game includes Teal definitions and shipped mods; the official manual's [introduction](https://wiki.transportfever3.com/doku.php?id=modding:introduction) says mods are directory-based and warns against editing installation files.
- The official [scripting reference](https://wiki.transportfever3.com/script-doc/) documents `api.engine` as read-only access to the engine state from both GUI and engine script states. It exposes `forEachEntityWithComponent`, `getComponent`, `ComponentType.GAME_SCRIPT`, and `Engine.Component.GameScript<T>.state`.
- TF3's public engine API exposes `api.engine.system.gameScriptSystem.getEntityForGameScript(name)`. The POC uses that accessor with `::/game_mechanics/subventions/subventions.gs`, the same resource name used by the installed base-game subsidy UI. `GAME_SCRIPT` can be read by entity, but TF3 rejects enumeration of that component type.
- The installed base type file `base/tealdef/game_mechanics/subventions/subvention.d.tl` defines `SubventionState` with `proposedSubventions`, `activeSubventions`, `completedSubventions`, and `failedSubventions`. A subsidy record includes status and timestamps; its data includes name, expiry durations, required quantity, delivered quantity, and upfront/completion/failure effects. Effects can be Money, Reputation, or TownExperience.
- The built-in UI types also define card data for description, deadline, progress, locations, cargo icons, and effects. A current community mod, [TF3 Minimap](https://github.com/schbrongx/tf3mod-minimap), demonstrates a bottom mod-button-area plugin, `builtin.Window`, a `ModEntryPointExtension`, and the current React GUI resource layout.
- `api.gui.game.getGuiSaveData(modId)` and `setGuiSaveData(modId, data)` are documented. They are suitable for mod-owned GUI preferences persisted with a save. The game's own script state is also part of save state.
- `api.gui.camera.focusEntity` and `focusPosition` are documented, so camera focus is possible when a relevant entity or position is available.

### Not Exposed or Uncertain

- The subsidy records and their lifecycle implementation are in `base/tealdef`, not in the public `api/tealdef` package. The engine accessor is officially read-only, but subsidy field names are base-game contracts and could change between game updates. The mod therefore guards for missing state and performs no writes.
- The base subsidy type declares lifecycle callbacks (`onAccept`, `onUpdate`, `onComplete`, `onFailure`), but there is no documented external-mod subscription hook for those callbacks. This POC uses an explicit Refresh control rather than adding a polling loop.
- The state shape has completed and failed collections, but the shipped type declarations alone do not establish how long those collections are retained. The POC displays records still present in those lists; long-term history retention needs in-game verification across completion, failure, save/reload, and multiple versions.
- The manager does not infer missing rewards, locations, or failure reasons. It dispatches each real record through its shipped `getCardData` helper; failures are logged per record and preserve the other rows.
- No supported direct-acceptance API was found. There is no acceptance action in this POC; use the game's normal subsidy interface.
- The shipped statistics tray has no dedicated mod extension point. The integration below depends on undocumented shipped GUI modules and must be rechecked after game updates.

## Using the Manager

Click **Subsidy Manager** beside **Industry Statistics** to open or close the native, movable window. Choose **In Progress**, **Offered**, or **History**, and use **Refresh** to reread the save. History distinguishes **Successful** and **Failed**. The list scrolls within the manager. No persistent launcher occupies the viewport.

Rows show the real title, cargo/passenger icons and quantity, available locations, native effect text, and appropriate remaining time. Active records show transported/required counts in a native progress bar. Successful history shows completion effects; failed history shows the failure effects exposed by TF3. Missing card data leaves a defensive name/progress fallback rather than inventing information.

Select a formatted row to open TF3's existing subsidy detail window. The game supplies the description, task, locations, money, income multipliers, durations, and other supported effects. Offered records expose the game's normal Accept/Decline controls there; the mod implements neither action. Native details may take over the active tool, just as when selected from vanilla subsidy notifications.

There is **no default shortcut** and no custom keyboard listener. F9 remains TF3's Screenshot action (`IA_GAME_SCREENSHOT`), confirmed in the installed user key definitions. Esc and other vanilla shortcuts use TF3's normal input routing.

The initial read runs once per manager window instance; switching tabs does not reread engine state. Refresh copies records and card data into a detached snapshot. Reopening the manager creates a fresh snapshot. No subsidy polling or persistent history database is added. Empty and unavailable states are explicit; a failed state read logs its cause and leaves Refresh available to retry.

## Native Integration Evidence

Implementation was checked against the installed TF3 resources, extracted to temporary files for inspection. No installation files were modified.

- `gui/game_bar/game_bar.tl`: `GameBarMenuRight` builds Industry Statistics (`menu.industry-statistics.button`, `IA_SELECT_STATISTICS_INDUSTRIES`) in its horizontal statistics group using `builtin.ToolButton`. `MainModButtonAreaExtension` belongs to a separate mod area, so its old launcher resources were removed.
- `gui/main/bootstrap_game.tl`: loads `react-replacement-config` resources before React initialization. The mod uses this mechanism and `RegisterWrapperRecipe` to wrap the exported `GameBar` recipe, preserving it with `react.CallOriginalRecipe` and retaining its game context. Wrapper registration supplies the native `innerRecipeId` metadata required when returning another recipe node. Revision 5 used ordinary recipe registration here and failed UI startup with **Recipe child must be a layout**; revision 6 corrects that registration.
- **Undocumented integration:** during that bootstrap callback, the mod wraps the shared `builtin.ToolButton` module function and adds a sibling only when the metadata ID is Industry Statistics. All original arguments, refs, and native button properties pass through. This avoids copying the vanilla toolbar implementation, but can conflict with mods replacing the same module/recipe. There is no public statistics-tray plugin API in this build.
- `gui/game_bar/game_bar.css.lua`: native ToolButton selectors supply the circular surface, hover/pressed/checked behavior and icon sizing. A mod-owned white contract/reward icon has the same 52×52 `@2x` asset size as the native 26-unit statistics icons. The small stylesheet uses the shipped 10-unit spacing and extends the native tray's minimum width by one icon plus gap; layout and stylesheet units follow UI scaling, with no screen-positioned launcher.
- `gui/main/tool_react_util.tl`: `registerToolWithWindow` owns creation, closing, shelving, and removal through the existing tool stack. Closing removes the manager instead of retaining the POC's hidden singleton. This addresses the potential input/focus interference from the old lifecycle without intercepting Esc or replacing the pause menu. The reported Esc failure had no accompanying Lua error in the inspected log; its resolution still requires an in-game input check.
- `game_mechanics/subventions/subventions_gui.tl`: dispatches `SubventionDesc.scriptFile .. ".getCardData"` via `util.useFn`. The manager uses the same full-card dispatch, on detached records because legacy helpers can migrate fields. Shipped helpers format money, other effects, income multipliers and durations. Offered summaries use `spawnTime + expireDurationProposed` (the shipped `defaultTimeout` contract) with `util.formatDurationWithCurrentCalenderSpeed`; vanilla card deadlines describe the task duration instead.
- `game_mechanics/notifications/types/subvention*.script.tl` and `gui/entity_window/make_non_entity_window.tl`: the manager fires the same `selectViewKey` event with `subsidy_<uid>` and the real detached record to open the vanilla detail. It does not copy the vanilla card or issue simulation commands.

TF3 removes completed records when their bonus expires in the inspected lifecycle code. History only displays records still retained by the game. Actual retention through failure, bonus expiry, and save/reload needs gameplay verification.

## Installation

This mod can be installed manually without changing any Transport Fever 3 game files. Copy the entire `mod/tf3_subsidy_manager_1` folder from this repository into the `mods` folder for your TF3 user data. For the Steam/Linux setup used during development, the destination is:

```text
~/.local/share/Steam/userdata/7253637/3493540/local/mods/
```

If the `mods` folder does not exist, create it. After copying, verify the manifest is at `.../local/mods/tf3_subsidy_manager_1/mod.json` (not in an extra nested `tf3_subsidy_manager_1` folder). Restart TF3, enable **Subsidy Manager (Proof of Concept)** in the mod list for a save, then load the save.

For another Steam account or platform, use that account's TF3 user-data `mods` directory; the Steam account ID and Steam library location may differ. Do not copy the mod into the game installation directory. TF3's mod browser uses mod.io; this source directory can also be packaged and shared manually.

Revision 6 uses the mod ID `tf3_subsidy_manager` and matching resource namespace. This identity rename removes the former branding; it is separate from the revision bump. Existing saves that enabled the previous mod identity may need the renamed mod enabled again in their mod list. The folder remains `tf3_subsidy_manager_1`, and the mod stores no simulation state to migrate.

## Removal

Disable the mod in the save's mod list, exit the game, and remove the `tf3_subsidy_manager_1` directory from the user-data `mods` directory. This POC stores no custom simulation or subsidy state, so removing it cannot remove or corrupt subsidy records.

## Development Checks

The game compiles `.tl` scripts when loading mods. For editor-side type checking, run from `mod/tf3_subsidy_manager_1`, set `TF3_INSTALL_DIR` to the TF3 install directory, and use the included `tlconfig.lua` and `all_def.d.tl` with Teal (`tl`). TF3 extends the upstream Teal definitions (including React metadata), so upstream checking may report framework compatibility errors; the game remains the authoritative compiler. The `.res.lua` files can be checked with `luac -p`.

Run the mocked regression checks from the repository root with Lua 5.3+ and a Teal source checkout:

```sh
TEAL_DIR=/path/to/tl lua5.4 tests/subsidy_manager_test.lua
```

The harness transpiles the actual mod script, rejects Teal syntax errors, and exercises the plugin recipes against mocked engine and React APIs. It covers named script lookup without enumeration, missing/invalid state, read failure and retry, snapshot isolation (including legacy helper writes), lazy initialization, all tabs, incomplete/nonfinite progress, complex native effect text, offer expiry, detail dispatch, toolbar argument forwarding, and tool close lifecycle. It does not replace the game's compiler or UI runtime.

The upstream Teal checker does not model TF3's injected React `meta` parameters. Diagnostics about `meta` on native Button/BoxLayout/ToolButton calls are framework metadata compatibility errors, also present in shipped UI code; they are separate from syntax or ordinary mod type failures. The game remains the authoritative compiler.

For the GameBar startup regression, also run the contract check against the installed game's actual React module (requires `unzip`):

```sh
unzip -p "$TF3_INSTALL_DIR/base/content/gui.zip" gui/main/react.lua > /tmp/tf3-react.lua
TEAL_DIR=/path/to/tl TF3_REACT_LUA=/tmp/tf3-react.lua lua5.4 tests/tf3_react_contract_test.lua
```

This check executes the shipped Lua recipe registration and node creation, verifies the wrapper's native metadata and original GameBar parameter forwarding, and rejects revision 5's registration under a modeled native layout constraint. The C++ renderer is mocked; this is stronger than plain-function recipe mocks but does not establish a successful in-game load.

Revision 6 still needs real in-game validation: load a real save without UI recovery errors; check toolbar placement/appearance at multiple UI scales and resolutions; toggle/close/reopen the manager; test Esc with the manager closed and open, F9 screenshots, F8 Industry Statistics, and other vanilla shortcuts; inspect active/offered/completed/failed rows and native details (especially money plus an income multiplier); test normal vanilla acceptance; and check history after save/reload and reward expiry. Mocked checks do not establish these runtime/visual acceptance criteria.
