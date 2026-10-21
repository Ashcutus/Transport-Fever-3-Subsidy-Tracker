# Changelog

## v1.3.1 — More reliable toolbar

- Renamed Auto-decline to **Hide offers**, with clearer guidance about reviewing missed subsidies later.
- Improved initialization of the bottom-bar launcher.
- Offer hiding and saved-offer handling remain active independently of the toolbar icon.

## v1.3.0 — Recover previously hidden subsidies

- Updated the real-game gallery with Auto-decline guidance and the missed-offer indicator.
- When missed offers become available after switching Auto-decline off, the toolbar icon shows its yellow dot too. Opening the manager clears the toolbar dot; opening Offered clears its separate dot.
- Turning Auto-decline off refreshes the overview immediately and updates it again when the availability check finishes.
- Auto-decline saves and declines new offers before they reach the offer notification flow, after the game confirms the option. Previously hidden offers do not set the manager’s toolbar dot.
- Auto-decline stays readable while waiting for a subsidy action, with a “please wait” label, an explanation on hover and retry guidance if confirmation fails.
- When you switch Auto-decline off, previously hidden offers appear directly in Offered and its count. A yellow dot marks offers waiting for review, with the available count on hover. Opening Offered clears the dot.
- Missed offers use the normal Offered columns and open the game’s usual details when clicked, with the normal Accept and Decline controls. Show declined includes manual declines too. Once revealed, missed offers stay visible and usable when Auto-decline is enabled again, including after a reload. Only newly incoming offers are hidden.
- Saved contracts keep their requirements, rewards and remaining offer time. Their offer timer pauses while saved; accepted-task deadlines are unchanged.
- Offers that are no longer valid appear in History as **Expired**, with an explanation and no failure penalty. Temporary read errors leave the offer available for another attempt.
- Recovery supports the four vanilla subsidy types and offers saved from this version onward. Older declines cannot be recovered.

## v1.2.0 — Auto-decline new offers

- Added an optional Auto-decline toggle beside Refresh, off by default, with a short explanatory tooltip.
- Your Auto-decline choice is saved per game. Existing offers and accepted tasks are preserved.
- Reorganised this description into an overview, usage guidance and release history.
- Added a real-game gallery image showing Auto-decline and its tooltip.

## v1.1.2 — Clearer overview and more reliable progress

- History shows each outcome once in Status, without a duplicate Result column.
- Missing values, including progress, use a dash with an explanatory tooltip.
- Clearer guidance when data cannot be read, and a more accurate empty History message.
- More available progress and rewards remain visible when a subsidy is difficult to read.
- Genuine zero worker progress appears as 0% Workers.

## v1.1.1 — Clearer guidance

- Clearer instructions for finding offers, following accepted tasks and reviewing past outcomes.
- Clarified that Refresh updates the overview while the manager is open.

## v1.1.0 — Easier-to-read tables and a fresh look

- Payments, bonuses and other effects appear on separate lines. Long rewards and durations wrap instead of being cut off.
- Better reward and deadline spacing, with rows that grow to fit their text.
- Illustrated empty views with section-specific guidance and a compact window when every section is empty.
- Refreshed cover and gallery showing the toolbar, updated tables and empty views.

## v1.0.1 — Description update

- Improved the Mod Hub summary and description.

## v1.0.0 — Initial release

- Added the toolbar launcher and Offered, In Progress and History views with counts.
- Compare subsidy resources, requirements, rewards and deadlines in one place.
- Open the game’s subsidy details and map highlights directly from a row, with the usual Accept and Decline controls.
- Manual Refresh and a movable, pinnable window with a compact all-empty layout.
