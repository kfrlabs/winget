# Table fixtures (issue #31)

Structural simulations of `winget list` / `winget upgrade` / `winget pin list`
outputs in EN, FR, DE, ES, IT and PT shapes. **These are NOT real captures**:
the header words for DE/ES/IT/PT are plausible localizations used only to
prove the parsers discover tables via the separator row and map columns
positionally (they never match header words). Real captures are welcome as
replacements (keep the same file names and UTF-8 encoding).

Layout: `<command>/<lang>.txt`, plus `-spinner` variants with progress frames
redrawn via `\r`. Every standard `upgrade` file parses to the same two rows
(`Git.Git`, `Notepad++.Notepad++`); `es` carries a second explicit-targeting
table (case-insensitive dedup keeps two rows). Every `pin_list` file parses
to `Git.Git` + `Google.Chrome`; every `list` file to the matching two
packages — including `list/es-bom.txt`, which additionally proves a BOM plus
a localized header parse end to end.

Extra shapes with dedicated expectations (excluded from the uniform loops):
- `upgrade/en-no-source.txt`: 4-column `[Name, Id, Version, Available]`
  table (no Source); versions are still read via the Available-word
  fallback. Other locales' 4-column Available words are not matched (real
  `winget upgrade` tables always carry Source).
- `upgrade/de-collapsed.txt`: German header with a name column as wide as
  its longest (truncated `…`) entry, so full cells keep a single-space gap
  while column starts stay on the header offsets.
- `wide/upgrade-de.txt`: CJK (BMP) and emoji (astral) package names under a
  German header (legacy char-aligned simulation, still parses).
- `wide/upgrade-display.txt` (issue #32): display-aligned CJK, accented,
  `…`-truncated and emoji names under a German header. Winget pads by
  display width, not by character count, so the CJK row uses fewer
  characters (80 vs 88) to reach the same 88 display columns; the parsers
  slice with `display_slice` / `Get-DisplaySubstring` (East Asian Width +
  astral wide) so all four rows parse in Ruby and PowerShell.

Parsing notes (mirrored Ruby ↔ PowerShell):
- Short rows slice leniently: a row ending inside the Available column
  yields its current version with a null available version (Ruby slicing
  never raises; the tasks guard every `Substring` to match).
- Row skipping tolerates leading whitespace (`^\s*[-=]+\s*$` both sides).
- Dedup is case-insensitive, first-seen casing wins (Ruby tracks
  `id.downcase`; PowerShell hashtables/`-notcontains` already ignore case).

PowerShell parity: `tasks/list_upgrades.ps1` and `tasks/upgrade_now.ps1`
implement the same algorithm (`Find-TableHeaders`, positional
`Get-ColumnOffsets` / `Get-AvailableOffset` with the same 4-column
fallback, `Remove-ProgressFrames`). There is no Pester harness on Linux, so
these fixtures double as the manual verification corpus: dot-source the
function definitions of either script on Windows (stop before
`$taskParams = Read-TaskParams`), feed each file with `Get-Content`, and
expect the same rows/IDs as the RSpec suite — including the short-row
(current version, null available), 4-column, BOM, collapsed and
case-variant cases above.
