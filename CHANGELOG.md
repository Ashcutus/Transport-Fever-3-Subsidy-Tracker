# Release Notes

## v1.1.2 — Cleaner overview messaging (revision 16)

- History shows outcomes once in Status; removed the redundant Result column.
- Missing overview values use a dash with an explanatory tooltip, including missing progress.
- Read failures offer a clear Refresh action; empty History describes only records retained by the game.

## v1.1.2 — More resilient progress reads

- If a full native subsidy card fails to load, retry the game’s lightweight card helper so available progress and rewards can still appear. This recovery also covers count-based tasks.
- Worker progress keeps genuine native zero values as “0% Workers”; unreadable data remains explicitly unavailable.
- Release checks now verify every packaged gallery image against its current approved source, preventing older previews from slipping into the ZIP.

## v1.1.1 — Clearer guidance

- Clearer Mod Hub instructions explain where to find offers, follow accepted tasks and review past outcomes.
- Clarified that Refresh updates the overview while the manager is open.
- Includes all v1.1.0 table, empty-view and gallery improvements below.

## v1.1.0 — A clearer overview, with a fresh look

- Easier-to-read rewards: payments, income bonuses and other effects now appear on separate lines. Long values and bonus durations wrap instead of being cut off.
- Better table spacing: rebalanced Reward and Deadline / Time Remaining widths, with rows growing to fit their text. The shared layout improvements cover In Progress, Offered and History.
- Illustrated empty views: each section now has a contract-and-route illustration, a friendly headline and useful guidance. The panels are centred and fit the compact window when all sections are empty.
- Friendlier Mod Hub information: rewritten the summary and description around what the mod helps you do and how to use it.
- A refreshed gallery: clean, consistent images made from real game captures, showing the updated tables, toolbar icon and all three compact empty views, with a clear benefit in each image.
- New cover artwork with a transport scene, a clearer title and the tagline “Your next opportunity, in view.”

## v1.0.1 — Metadata Update

- Improved Mod Hub description and summary.
- No gameplay or functionality changes.

## v1.0.0 — Initial Release

- Native Subsidy Manager toolbar integration.
- Offered, In Progress and History views with counts.
- Compact subsidy tables with native resource information.
- Open subsidies directly in TF3's native detail UI, including map highlighting.
- Native Accept/Decline workflow preserved.
- Manual Refresh.
- Compact window preset when the entire overview is empty.
- No simulation changes or custom subsidy state.
