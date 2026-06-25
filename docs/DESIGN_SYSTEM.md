# Design System

Mango's visual language is warm, calm, and Claude-like: cream surfaces, a single
terracotta accent, an editorial serif for display type, generous whitespace, and
soft rounded cards. Everything adapts to light and dark automatically and scales
with Dynamic Type. The tokens live in `ios/Mango/DesignSystem/` —
`Theme.swift` (colors, spacing, radius), `Typography.swift`, `Components.swift`,
`Haptics.swift`, and the `Color(hex:)` / `Color(light:dark:)` helpers in
`Color+Hex.swift`.

## Color tokens

Colors are defined in `Theme.swift` under the `Palette` enum. Adaptive tokens use
`Color(light:dark:)`, which resolves against the active trait collection so a
single token works in both schemes.

| Token | Light | Dark | Use |
|---|---|---|---|
| `terracotta` / `accent` | `#D97757` | (same) | Brand accent, primary buttons, links |
| `terracottaDeep` | `#C15F3C` | (same) | Pressed/deep accent |
| `background` | `#FAF9F5` | `#191917` | App background (warm cream / near-black) |
| `surface` | `#FFFFFF` | `#262624` | Cards and raised surfaces |
| `surfaceAlt` | `#F1F0E9` | `#302F2C` | Track fills, ring backgrounds |
| `textPrimary` | `#1F1E1D` | `#ECEAE3` | Headlines, body |
| `textSecondary` | `#6B6A64` | `#A8A69D` | Supporting copy |
| `textTertiary` | `#94928A` | `#74726B` | Hints, disabled |
| `border` | `#E7E5DB` | `#3A3A36` | Hairline card borders |
| `success` | `#5F7345` | `#9CB37A` | Application exercises |
| `info` | `#4F7CA8` | `#8FB4D9` | Quiz exercises |
| `warning` | `#B5832F` | `#E0B25E` | Cautions |
| `danger` | `#A93F30` | `#D98373` | Destructive |
| `streak` | `#E8835A` | (same) | Streak flame/pill |
| `xp` | `#B5832F` | `#E0B25E` | XP bars |

## Typography

`Typo` (`Typography.swift`) uses a **serif (New York)** for display and titles —
`display`, `title`, `title2`, `title3` — to echo Claude's editorial feel, and
**SF Pro** for UI and body (`headline`, `body`, `bodyEmphasis`, `callout`,
`subheadline`, `footnote`, `caption`). Every token is built on a Dynamic Type
text style (`.largeTitle`, `.title`, `.body`, …), so the whole app scales with the
user's accessibility text-size setting rather than using fixed point sizes.

## Spacing, radius, and shape

`Metrics` (`Theme.swift`) centralizes layout constants: padding (`pad` 16,
`padL` 24), `gap` 12, corner radii (`radius` 18, `radiusSmall` 12, `radiusPill`
999), and a 1pt `hairline`. Cards and buttons use continuous-corner
`RoundedRectangle`s for a soft, rounded feel. The `.mangoBackground()` view
extension applies the standard cream/near-black screen background.

## Components

All shared components live in `Components.swift`:

- **Card** — the workhorse surface: padded content on `surface` with a hairline
  `border` and an 18pt continuous radius.
- **Tag** — a small capsule label (optional SF Symbol) tinted by an accent color
  at low opacity; used for source kinds and exercise types.
- **ProgressRing** — a trimmed `Circle` with a rounded line cap and a spring
  animation on change; powers the daily-goal ring.
- **XPBar** — a capsule progress bar (defaults to the `xp` tint) that animates its
  fill fraction toward a goal.
- **StreakPill** — a flame icon plus the day count on a `streak`-tinted capsule,
  with an accessibility label ("N day streak").
- **BookCover** — a generated cover (no image assets) built from a hue gradient
  with the serif title overlaid, so any imported book gets a distinct, on-brand
  cover.
- **Buttons** — `MangoPrimaryButtonStyle` (filled terracotta, with a disabled
  state and a press scale/spring) and `MangoSecondaryButtonStyle` (bordered
  surface), exposed as `.mangoPrimary` / `.mangoSecondary`.
- Plus `SectionHeader` and `EmptyStateView` for consistent screen scaffolding.

## Light/dark and accessibility

The whole palette is dual-tone, and the app honors a user theme preference
(`system` / `light` / `dark`) applied via `preferredColorScheme`. Type is fully
Dynamic-Type-relative. Colors are chosen for **AA contrast**, and the semantic and
gamification colors are kept **colorblind-distinguishable** — but, by intent, they
are **always paired with an icon or label** (e.g. exercise kinds carry both a tint
and a distinct SF Symbol; the streak pill carries a flame and a number), so meaning
never rests on color alone. Tactile feedback comes from `Haptics` — light/soft/
rigid impacts, success/warning notifications, and selection changes — applied at
key microinteractions like advancing a lesson or completing an exercise.
