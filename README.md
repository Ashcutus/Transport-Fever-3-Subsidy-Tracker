# Subsidy Manager for Transport Fever 3

Keep offered, active and historical subsidies in one place. Compare the available opportunities, track progress, and click a subsidy to open Transport Fever 3's own detail window.

## Features

- Native toolbar button beside Industry Statistics.
- **Offered**, **In Progress** and **History** views with subsidy counts.
- Readable tables showing available type, resource, destination, requirement or progress, rewards and remaining time. Click column headers to sort.
- Native subsidy details, map highlighting and the game's Accept/Decline controls.
- A separate **Refresh** button to update the overview whenever you need it.
- Native styling, a movable window and a compact preset when the whole snapshot is empty.
- No changes to subsidy rules or simulation state.

## Screenshots

Screenshots are coming before publication. Contributors can use the prepared [capture notes and image locations](docs/screenshots/README.md).

## Installation

**Mod Hub:** Once published, find **Subsidy Manager** in TF3's Mod Hub, subscribe, then enable it for your save. A listing link will be added here after publication.

**Manual installation:** Download the release ZIP and extract its `tf3_subsidy_manager_1` folder into your TF3 user-data `mods` directory. Enable **Subsidy Manager** for your save. Use your own TF3 user-data folder, rather than the game installation directory. Developers can instead copy `mod/tf3_subsidy_manager_1` from this repository.

## Usage

1. Load a save with the mod enabled.
2. Click **Subsidy Manager** in the bottom-right toolbar, beside Industry Statistics.
3. Choose **Offered**, **In Progress** or **History**.
4. Click a row to open the game's subsidy details.

Use **Refresh** after subsidies change. The game handles acceptance and decline in its native detail window. No keyboard shortcut is required.

## Compatibility

The revision 9 baseline has been tested in a real TF3 save on Linux. Windows, macOS, Xbox and PlayStation testing has not been performed. The new compact-empty window preset still requires visual testing.

TF3's Mod Hub/mod.io supports distribution across desktop and console platforms; availability of this mod depends on its processing and approval. Console compatibility has not been verified. [Urban Games' mod distribution overview](https://www.transportfever3.com/news/dev-blog-episode-5-highlights/) explains the pipeline.

Mods that replace the same toolbar or subsidy UI may conflict. Future TF3 updates may require compatibility updates.

## Known limitations

- Refresh is manual; the overview does not update continuously.
- History shows only records still retained by TF3, not a permanent archive.
- Missing native fields are left unavailable. The game's detail window remains the complete source of information.
- English is the currently supplied language.

## Version

**v1.0.0 — Initial Release**, prepared for publication. See [release notes](CHANGELOG.md). TF3's internal manifest revision is a separate update counter.

## Feedback / Issues

Report problems or suggest improvements through [GitHub Issues](https://github.com/Ashcutus/Transport-Fever-3-Subsidy-Tracker/issues). Include the mod revision, TF3 version, platform and a screenshot or error log where useful.

## Credits

Transport Fever 3 is developed by Urban Games. This is an independent community mod, with no affiliation or endorsement implied.

## License

Subsidy Manager is licensed under the [MIT License](LICENSE). You may use, modify, fork and redistribute it under the standard MIT terms.

For contributors and release maintainers: [development checks](docs/DEVELOPMENT.md) and [release preparation](docs/RELEASE.md).
