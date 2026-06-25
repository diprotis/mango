# Mango Design System

Mango's look is **Claude-consistent**: warm cream surfaces, a terracotta accent,
editorial serif headings, generous whitespace, and calm motion. Everything is
token-driven — raw hex lives only in `ios/Mango/DesignSystem/Theme.swift`, enforced
by `ios/scripts/check_theme.sh` (run in iOS CI). See spec
[specs/0002-claude-ui-theme.md](specs/0002-claude-ui-theme.md).

## Color tokens (`Palette`)

| Token | Light | Dark | Use |
|---|---|---|---|
| `background` | `#FAF9F5` | `#1A1A18` | screen background (warm ivory) |
| `surface` | `#FFFFFF` | `#262624` | cards, sheets |
| `surfaceAlt` | `#F1F0E9` | `#302F2C` | track/fills, inset wells |
| `textPrimary` | `#1F1E1D` | `#ECEAE3` | body + headings |
| `textSecondary` | `#6B6A64` | `#A8A69D` | supporting text |
| `textTertiary` | `#8A887F` | `#74726B` | hints, disabled |
| `border` | `#E7E5DB` | `#3A3A36` | hairline borders |
| `accent` | `#D97757` | `#D97757` | terracotta — primary actions |
| `accentPressed` | `#C15F3C` | `#C15F3C` | pressed state |
| `onAccent` | white | white | text/icons on accent |
| `success` | `#5F7345` | `#9CB37A` | positive (with icon) |
| `info` | `#4F7CA8` | `#8FB4D9` | informational |
| `warning` | `#B5832F` | `#E0B25E` | caution |
| `danger` | `#A93F30` | `#D98373` | destructive |
| `streak` | `#E8835A` | `#E8835A` | flame |
| `xp` | `#B5832F` | `#E0B25E` | XP/level |
| `shadow` | ink @12% | black @50% | sparing elevation |

**Contrast:** text tokens target WCAG AA (≥4.5:1) on their intended surfaces in both
modes. `onAccent` (white) on `accent` (#D97757) ≈ 3.0:1 — acceptable for bold button
text (large/bold); revisit if used at small sizes. Meaning is **never** carried by
color alone — semantics always pair with an SF Symbol or a label.

## Typography (`Typo`)

Serif (Apple **New York**) for display/titles, **SF Pro** for UI/body, everything
relative to Dynamic Type text styles.

| Token | Style |
|---|---|
| `display` | largeTitle · serif · bold |
| `title` / `title2` / `title3` | title* · serif · semibold |
| `headline` | headline (SF) |
| `body` / `bodyEmphasis` | body (SF) |
| `callout` / `subheadline` / `footnote` / `caption` | SF |
| reader | `.system(.body, design: .serif)` with extra line spacing |

## Spacing & radius (`Metrics`)

`pad 16` · `padL 24` · `gap 12` · `radius 18` (cards) · `radiusButton 14` ·
`radiusSmall 12` · `radiusXS 8` (book cover) · `hairline 1`.

## Components (`Components.swift`)

`Card` (surface + hairline border, radius 18) · `MangoPrimaryButtonStyle` (accent →
accentPressed, onAccent label) · `MangoSecondaryButtonStyle` (surface + border) ·
`Tag` · `ProgressRing` · `XPBar` · `StreakPill` · `SectionHeader` · `EmptyStateView` ·
`BookCover` (hue-generated, no image assets). Reuse these — don't re-roll one-offs.

## Motion

One spring (`response 0.3–0.5`) for transitions; XP via `.contentTransition(.numericText())`;
node unlock via `PhaseAnimator`. **Reduce Motion** is honored — `ProgressRing`, `XPBar`,
and the lesson-complete celebration disable their animations when it's on.

## Accessibility

- Dynamic Type throughout (no fixed font sizes for content); test at XXL.
- Full light/dark parity.
- Colorblind-safe: never color-only; icon/label always present.
- Haptics on key interactions (`Haptics`), tactile but not noisy.

## Do / Don't

- ✅ Use `Palette` / `Typo` / `Metrics` tokens. ❌ Don't write raw hex or `.white`/`.black`
  outside `DesignSystem/` (CI blocks it).
- ✅ Lead with whitespace + hairline borders. ❌ Don't pile on heavy shadows.
- ✅ Pair color with an icon/label. ❌ Don't signal state with color alone.
