# Development

Runtime findings and regression-sensitive contracts live in [AGENTS.md](../AGENTS.md). The published v1.0.0 release is the runtime baseline for the metadata-only v1.0.1 update. Mocks and type checking cannot replace native C++ layout/painting tests.

Set `TF3_INSTALL_DIR` to your game installation and `TEAL_DIR` to a Teal source checkout. Extract the shipped contracts without editing game files:

```sh
unzip -p "$TF3_INSTALL_DIR/base/content/gui.zip" gui/main/react.lua > /tmp/tf3-react.lua
unzip -p "$TF3_INSTALL_DIR/base/content/gui.zip" gui/main/stylesheetutil.lua > /tmp/tf3-stylesheetutil.lua
unzip -p "$TF3_INSTALL_DIR/base/content/gui.zip" gui/main/engine_react_util.tl > /tmp/tf3-engine-react-util.tl
TEAL_DIR="$TEAL_DIR" lua5.4 tests/subsidy_manager_test.lua
TEAL_DIR="$TEAL_DIR" TF3_REACT_LUA=/tmp/tf3-react.lua lua5.4 tests/tf3_react_contract_test.lua
TF3_STYLESHEETUTIL_LUA=/tmp/tf3-stylesheetutil.lua lua5.4 tests/tf3_stylesheet_contract_test.lua
TEAL_DIR="$TEAL_DIR" TF3_ENGINE_REACT_TL=/tmp/tf3-engine-react-util.tl lua5.4 tests/offer_badge_test.lua
python3 tests/release_package_test.py
```

The tests cover state isolation, malformed/partial data, 20-record sections, native progress/effects/expiry, detail selection, Refresh/rebuilt cells, tabs/counts, native wrapper registration/forwarding, content boundaries, shared inset, internal table stretch and scoped toolbar sizing. Sizing tests check classes/presets and stability across tabs, not real pixels.

For installed-definition checking, use `tlconfig.lua` and `all_def.d.tl` from `mod/tf3_subsidy_manager_1`, with `TF3_INSTALL_DIR` set. Upstream Teal cannot model TF3's injected React `meta` fields: expected metadata compatibility diagnostics are recorded in AGENTS. All other errors must be investigated.

Check Lua resource/stylesheet syntax with `luac -p`, all JSON/translation and image references, and `git diff --check`. Routine PR revision rules are in AGENTS.md. The maintainer explicitly requires revision 12 to remain unchanged for the v1.0.1 metadata-only release.

Build a runtime-only archive with `python3 scripts/package_release.py`; its allowlist excludes editor definitions/configuration and developer documentation. The repository can retain these development files. See [release preparation](RELEASE.md) before publishing.
