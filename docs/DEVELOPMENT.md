# Development

Runtime findings and regression-sensitive contracts live in [AGENTS.md](../AGENTS.md). Revision 9 is the real-game UAT baseline. Mocks and type checking cannot replace native C++ layout/painting tests.

Set `TF3_INSTALL_DIR` to your game installation and `TEAL_DIR` to a Teal source checkout. Extract the shipped contracts without editing game files:

```sh
unzip -p "$TF3_INSTALL_DIR/base/content/gui.zip" gui/main/react.lua > /tmp/tf3-react.lua
unzip -p "$TF3_INSTALL_DIR/base/content/gui.zip" gui/main/stylesheetutil.lua > /tmp/tf3-stylesheetutil.lua
TEAL_DIR="$TEAL_DIR" lua5.4 tests/subsidy_manager_test.lua
TEAL_DIR="$TEAL_DIR" TF3_REACT_LUA=/tmp/tf3-react.lua lua5.4 tests/tf3_react_contract_test.lua
TF3_STYLESHEETUTIL_LUA=/tmp/tf3-stylesheetutil.lua lua5.4 tests/tf3_stylesheet_contract_test.lua
python3 tests/release_package_test.py
```

The tests cover state isolation, malformed/partial data, 20-record sections, native progress/effects/expiry, detail selection, Refresh/rebuilt cells, tabs/counts, native wrapper registration/forwarding, content boundaries, shared inset, internal table stretch and scoped toolbar sizing. Sizing tests check classes/presets and stability across tabs, not real pixels.

For installed-definition checking, use `tlconfig.lua` and `all_def.d.tl` from `mod/tf3_subsidy_manager_1`, with `TF3_INSTALL_DIR` set. Upstream Teal cannot model TF3's injected React `meta` fields: expected metadata compatibility diagnostics are recorded in AGENTS. All other errors must be investigated.

Check Lua resource/stylesheet syntax with `luac -p`, all JSON/translation and image references, and `git diff --check`. Before each PR, bump the current manifest integer revision by exactly one, keep the mod ID, and document the new revision independently of the public version.

Build a runtime-only archive with `python3 scripts/package_release.py`; its allowlist excludes editor definitions/configuration and the SVG icon source. The repository can retain these development files. See [release preparation](RELEASE.md) before publishing.
