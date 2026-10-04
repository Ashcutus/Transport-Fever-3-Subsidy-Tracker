# v1.0.0 release preparation

Public version: **v1.0.0**. TF3 internal revision: **10**, incremented from the revision 9 UAT baseline. Identity: `tf3_subsidy_manager`.

## Prepared

- Public README, release notes and screenshot locations.
- Display name **Subsidy Manager**, concise summary, English description with usage and compatibility limits, creator credit, `Script Mod` / `Misc` tags and GitHub URL.
- No required external mods; existing dependency/incompatibility fields remain unchanged.
- `VERSION`, release notes, archive filename and supported description text carry the public version. No unsupported semantic-version or platform field was added to TF3 JSON. mod.io's file release version is independently editable; use **1.0.0** there when the publishing workflow permits it. [mod.io file documentation](https://docs.mod.io/restapi/docs/edit-modfile).
- No local filesystem, external process, network, or keyboard-shortcut requirement in the shipped runtime. All mod-owned assets are packaged; base-game resource references resolve through TF3.

## Package

```sh
python3 scripts/package_release.py
```

This produces `dist/subsidy-manager-v1.0.0.zip` and a SHA-256 sidecar. The ZIP contains the `tf3_subsidy_manager_1` folder for manual installation. Its runtime allowlist includes the manifest, translations, descriptive metadata, plugin script/resource/stylesheet and toolbar TGA. Approved numbered preview PNGs are included when present. The standard MIT notice is included as `license.txt`. Tests, editor definitions/configuration, SVG source, developer documentation and repository configuration are excluded.

For native publishing, extract that folder into your own TF3 user-data `staging_area`, then use Mod Hub → My Mods. Complete the game's upload validation and review its platform results. No account upload, public release/tag or Mod Hub listing was created by this preparation pass. The [official publishing instructions](https://wiki.transportfever3.com/doku.php?id=modding:general:publishing) describe staging, gallery editing and generated upload identity; retain the generated `_metadata/mod.io_fileid.txt` after first upload so future updates target the same listing.

## Before publication

1. Test the compact-empty preset: all-empty snapshot opens compact; navigation stays stable; manual Refresh can change to/from table sizing. When any list has records, every tab must retain revision 9 dimensions, padding, stretch, scrolling and selection.
2. Add genuine screenshots. `_metadata/0.png` is the cover; use numbered PNGs at 1920×1080 for gallery images. No screenshot or preview has been invented. [Metadata requirements](https://wiki.transportfever3.com/doku.php?id=modding:general:moddefinition).
3. Confirm the archive includes the standard MIT notice from [LICENSE](../LICENSE). The license was explicitly selected by the maintainer; no additional restrictions apply.
4. Run all checks in [DEVELOPMENT.md](DEVELOPMENT.md), rebuild the ZIP, review its contents and upload validation. Set the public file version to 1.0.0 where supported, and use [CHANGELOG.md](../CHANGELOG.md) for the initial release text.

## Platform evidence and limits

Revision 9 was tested on Linux with working toolbar fit, shared inset, offered/history tables, empty active view, native detail/map highlighting and offered Accept/Decline. The compact-empty sizing change has not had a new game run. Windows, macOS and console behavior are untested; populated active/large-record behavior is covered by mocks, not newly claimed real-game evidence.

Urban Games describes automatic console optimization in its [Mod Hub overview](https://www.transportfever3.com/news/dev-blog-episode-5-highlights/). No hand-built console fork is needed for this preparation. Eligibility depends on TF3/mod.io validation and platform approval; it is not established here.

The official [guidelines](https://wiki.transportfever3.com/doku.php?id=modding:general:guidelines) call for official scripting APIs and impose additional console restrictions, including custom shaders. This mod has no custom shader, executable or simulation mutation, but the proven toolbar integration uses undocumented shipped GUI internals. That may affect upload validation/eligibility and needs verification rather than an unsupported compatibility promise. The small native-style TGA uses the same asset convention as shipped toolbar icons; platform texture processing still needs the game's validation. The referenced guideline/publishing pages currently display an old-revision notice, so confirm the uploader's current checks before publication.
