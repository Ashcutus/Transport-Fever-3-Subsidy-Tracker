## Pull Request Versioning

- Before opening every pull request, increment the integer `revision` in `mod/tf3_subsidy_manager_1/mod.json` by exactly one from the current value. This applies to documentation-only pull requests as well as mod changes.
- Include the revision change in the same pull request and mention the new revision in its description.
- Do not change the mod ID as part of routine version bumps.
- The user explicitly requested a complete branding removal in PR #5. That PR separately renames the identity/resource namespace to `tf3_subsidy_manager`; keep resource references consistent and document that existing saves may need the renamed mod enabled again.

## TF3 Development Findings

These findings come from the installed TF3 resources and real game logs inspected in October 2026. Shipped GUI internals are undocumented contracts: verify them against the installed build before changing an integration. Do not treat mocked tests as proof of a successful game load.

### Resource Investigation

- The development installation is `/mnt/ssd-games/SteamLibrary/steamapps/common/Transport Fever 3`. Steam libraries can differ; inspect `libraryfolders.vdf` if this path is unavailable.
- Public API declarations are in `api/tealdef`; base-game contracts are in `base/tealdef`. Shipped GUI implementations are in `base/content/gui.zip`; subsidy implementations are in `base/content/game_mechanics.zip`. Extract to `/tmp` for inspection. Never edit game installation resources.
- The inspected user's latest log is `~/.local/share/Steam/userdata/7253637/3493540/local/crash_dump/stdout.txt`. Account IDs may differ. Review the exact current log and full exception chain, rather than guessing from a screenshot alone.
- Resource files named `.res.lua` expose `data()`. `react-replacement-config` uses `filePath`, `doReplaceFn`, and `order`; `gui/main/bootstrap_game.tl` loads these before React initialization through `util.useFn(filePath .. "@" .. doReplaceFn)`.

### React Recipe/Layout Contract — Confirmed Startup Regression

- **Revision 5 failed real UI startup** with `Recipe child must be a layout`, naming the manager's GameBar delegation. The log points to native `react_transform.cpp:274`, `TransformDefault`.
- `react.CallOriginalRecipe(original, params)` creates a node for the original recipe. It does not execute that recipe and return its underlying layout immediately.
- An ordinary `RegisterRecipe` that delegates by returning this original recipe node violates the default native layout-child contract. Use `RegisterWrapperRecipe(name, originalRecipe, fn)` when returning that wrapped recipe node. This supplies `_react.recipeMetas[wrapperId].innerRecipeId`; the shipped React implementation checks the wrapped child against the original recipe.
- The GameBar delegation must use wrapper registration around the original `gameBar.GameBar`. Preserve `CallOriginalRecipe` to bypass the replacement and avoid recursion. Do not register a second ordinary recipe around it.
- The manager window already uses `RegisterWrapperRecipe(..., builtin.Window, ...)`. Keep it that way.
- `CallOriginalRecipe` is explicitly unsupported for builtins in shipped `react.lua`. Do not use it as a way to intercept native Button/ToolButton/BoxLayout recipes.
- Recipe calls can carry refs and styles before their parameters. Forward every argument unchanged when wrapping a module function; preserve original native refs. Do not simplify forwarding to only one or two arguments.

### Toolbar and Input

- `gui/game_bar/game_bar.tl` builds the right-hand statistics tray in `GameBarMenuRight`. Industry Statistics is `menu.industry-statistics.button`, with `IA_SELECT_STATISTICS_INDUSTRIES` (F8 in the inspected key definitions). It uses native `builtin.ToolButton` and the game's tool stack.
- `MainModButtonAreaExtension` is a separate mod-button area, not the statistics tray. Its old launcher/host resources were removed from this mod. Do not reintroduce a viewport overlay as a fallback.
- No dedicated statistics-tray plugin extension was found in the inspected build. Current integration wraps the exported GameBar to retain its game context and wraps the shared `builtin.ToolButton` module function, targeting only the Industry Statistics metadata ID and adding a sibling layout. This is an **undocumented hook**, not a public tray API; consider interactions with other mods replacing those internals and recheck after updates.
- Preserve the original Industry Statistics button and its properties/refs. Unrelated native buttons must pass through unchanged. Do not rebuild/copy the vanilla game bar or position the launcher with screen coordinates.
- `gui/game_bar/game_bar.css.lua` supplies native ToolButton circular surfaces, hover/pressed/checked styling. The inspected tray has seven 52×52 `@2x` icon assets (26 logical units), a 10-unit horizontal gap, and a 508-unit width. Current stylesheet extends the minimum width to 570 for one additional icon plus gap. Native stylesheet units follow UI scaling; actual placement at multiple resolutions/scales still requires game testing.
- The mod-owned contract/reward icon is `icons/contract_26@2x.tga`; `contract.svg` is its editable source. The game references the logical `contract_26.tga` path, as vanilla does for `@2x` assets. Do not substitute the large purple notification graphic.
- **No default keyboard shortcut is wanted.** F9 is already Screenshot (`IA_GAME_SCREENSHOT`), confirmed in the installed user's `settings_keys_v3.lua`. Do not override it, choose another default key, or add a global keyboard listener.
- Use `tool_react_util.registerToolWithWindow` and native tool-stack push/pop. The manager Window's `tool` name and `onClose` must match that lifecycle. It removes the window on pop and shelves it when another native tool takes over. Do not retain a permanently mounted hidden singleton or add a window-creation timer.
- Esc interference was reported with the old POC. No Lua error in the earlier inspected log established its cause. The native lifecycle change addresses possible retained-window/focus interference, but **Esc has not been confirmed fixed in-game**. Do not present that hypothesis as a proven root cause or claim verification without testing.

### Subsidy State and Native Details

- Preserve the working named lookup: `api.engine.system.gameScriptSystem.getEntityForGameScript("::/game_mechanics/subventions/subventions.gs")`, then read `GAME_SCRIPT` by entity. TF3 rejects enumeration of that component type; never reintroduce `forEachEntityWithComponent(..., GAME_SCRIPT)`.
- Read the existing `proposedSubventions`, `activeSubventions`, `completedSubventions`, and `failedSubventions` collections defensively. Keep explicit unavailable/error/empty states and per-record fallback handling. Never generate example records in gameplay or write simulation state.
- `game_mechanics/subventions/subventions_gui.tl` resolves each subsidy ID via `api.res.genericRep`, reads `SubventionDesc.scriptFile`, and dispatches `util.useFn(scriptFile .. ".getCardData")`. Use this full native card helper (`lightweight = false`) for overview data instead of inventing a payout schema.
- Native helper data covers title/description, cargo/passenger icons and quantity, locations, progress/deadline, upfront/completion/failure effects. Complex temporary income effects and their durations are added by subsidy-specific helpers, not just the generic Money/Reputation/TownExperience type declaration.
- Copy records before invoking native helpers: legacy helpers can migrate fields in-place. Keep records/card data detached from engine tables and clone the detail-event record too. Isolate helper failures per record so one malformed subsidy does not erase the other lists.
- Vanilla card `deadline` can describe the task duration rather than the remaining offered timeout. Offered expiry follows `spawnTime + data.expireDurationProposed`, verified in `subvention_util.defaultTimeout`. `-1` means no offered expiry. Use the actual timestamp and `util.formatDurationWithCurrentCalenderSpeed`, not a manual duration formatter or the task deadline. Refresh remains manual; add no mod-owned polling.
- Open native subsidy details with the vanilla notification event contract: `react.fireEvent(nil, "selectViewKey", { nonEntity = "subsidy_" .. uid, stack = false, extraParam = detachedRecord })`. `gui/entity_window/make_non_entity_window.tl` routes that key to the native subsidy presentation. No custom acceptance implementation is needed; the game owns its detail window's Accept/Decline actions.
- History labels come from collection membership: Successful vs Failed. Show completion effects for successful entries and failure effects/consequences exposed by TF3 for failed entries. Do not infer missing consequences or treat completion rewards as failure effects.
- Inspected lifecycle code removes completed entries after their bonus expires. This mod reports retained TF3 history only; do not promise permanent history or add a custom database. Actual retention across failure, expiry, and save/reload still needs gameplay verification.

### Checks and Their Limits

- `TEAL_DIR=/path/to/tl lua5.4 tests/subsidy_manager_test.lua` transpiles the real mod script and tests state reads, detached snapshots, malformed records, native card dispatch, complex effects, offered expiry, detail selection, argument/ref forwarding, and tool/window parameter wiring.
- The original plain-function recipe mock missed the revision 5 layout regression. Preserve the distinction between ordinary recipes and wrappers in the harness; do not weaken it to make a test pass.
- Also run `tests/tf3_react_contract_test.lua` against the installed game's actual Lua React implementation:

  ```sh
  unzip -p "$TF3_INSTALL_DIR/base/content/gui.zip" gui/main/react.lua > /tmp/tf3-react.lua
  TEAL_DIR=/path/to/tl TF3_REACT_LUA=/tmp/tf3-react.lua lua5.4 tests/tf3_react_contract_test.lua
  ```

  This exercises actual Lua registration/opaque node creation, validates `innerRecipeId` and original GameBar parameter forwarding, and mutation-tests revision 5's registration against a modeled native layout rule. The C++ transform remains mocked; it does not prove that a real save loads.
- Check `.res.lua` and `.css.lua` syntax with `luac -p`, resource entry-point/asset references, manifest revision/mod ID, and `git diff --check`.
- Upstream Teal does not model TF3's injected React `meta` arguments on some native Button/BoxLayout/ToolButton calls. Document these framework compatibility diagnostics separately; do not dismiss ordinary type errors, syntax errors, or actual native transform failures as metadata noise.
- Required in-game verification includes a real save loading without UI recovery errors, toolbar appearance at multiple scales/resolutions, manager toggle/close/reopen, Esc with the manager closed/open, F9 Screenshot, F8 Industry Statistics and other shortcuts, real state-specific details/complex effects, vanilla acceptance, and history after save/reload/bonus expiry.
- Keep PR validation claims precise. A passing Lua/type/mock check is not an in-game run. Note remaining runtime/visual validation explicitly, including whether the installed user-data mod has actually been updated.
