# v1.0.1 release preparation

Public version: **v1.0.1**. TF3 internal revision: **12**, unchanged. Mod identity: `tf3_subsidy_manager`. Folder identity: `tf3_subsidy_manager_1`.

## Scope

v1.0.0 is already published on mod.io. v1.0.1 updates the existing listing's description and summary only. Runtime code, UI, subsidy behaviour and assets are unchanged.

The committed public metadata retains author **Ashcutus**, name **Subsidy Manager**, the improved description beginning “Never lose track of a subsidy again.”, the summary, `Misc` / `Script Mod` tags and the existing GitHub URL.

`VERSION` defines the public version and manual-install archive filename. The description does not need an embedded version. No public version or platform fields are added to TF3 JSON. Use **1.0.1** as the mod.io file version during manual publication.

## Local package validation

```sh
python3 tests/release_package_test.py
python3 scripts/package_release.py
```

The local artifact is `dist/subsidy-manager-v1.0.1.zip`, with a `.zip.sha256` sidecar. The archive contains the existing `tf3_subsidy_manager_1` folder and allowlisted runtime files, including metadata and the MIT notice. Approved numbered metadata PNGs are included when present. Generated `dist/` files are ignored by Git.

Repository screenshots and a cover are not included here. This is not a new-listing blocker: preserve the existing published listing and its gallery. No placeholder assets are required.

## Manual publication handoff

Run the checks in [DEVELOPMENT.md](DEVELOPMENT.md), review the archive/checksum and use the [v1.0.1 release notes](../RELEASE_NOTES.md).

Update the existing **Subsidy Manager** item through TF3's Mod Hub → My Mods. Preserve existing mod.io IDs and publication-linkage metadata, including `_metadata/mod.io_fileid.txt` wherever the native uploader has generated it. No linkage file is tracked in this repository; do not replace the existing publication setup with a new item or invent an ID.

Repository preparation does not modify the local TF3 staging area, upload, publish, tag, push or create a mod.io item. The maintainer handles staging and publication manually.

## Validation and runtime evidence

The maintainer reports that PC/console package validation has occurred for the published release. This is separate from runtime testing: Linux gameplay has been tested; Windows, macOS, Xbox and PlayStation runtime testing has not been performed.

Completed pre-v1 visual UAT is not an outstanding requirement for this metadata-only update. Lua mocks and contract checks do not establish native C++ layout, painting or cross-platform runtime compatibility. Mods replacing the same toolbar internals may conflict, and TF3 updates may require compatibility review.
