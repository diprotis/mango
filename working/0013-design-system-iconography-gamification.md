# 0013 — Design system: iconography cleanup + tasteful gamification

- **Epic:** M11 · **Status:** Draft · **Owner:** unassigned · **Updated:** 2026-06-28
- **Reviewers:** Principal/SD/QA

## 1. Summary
Two coupled design-system upgrades, no new product surface. **(1) Iconography & emoji
cleanup:** today the app scatters keyboard emoji (`🥭`, `🎉`, `🌱`) directly in `Text(...)`
and pulls SF Symbol names as bare string literals (`"flame.fill"`, `"map"`, `"play.fill"`,
…) at every call site. We replace every keyboard-emoji literal with a **theme-based icon**
(curated SF Symbols, optionally a tiny custom symbol set for the mango mark), and introduce a
single **semantic icon vocabulary** — a `MangoSymbol` enum + an `Icon` view — so the rest of
the app references `MangoSymbol.streak` instead of `"flame.fill"`. A CI guard
(`check_no_emoji.sh`, mirroring the existing `check_theme.sh`) keeps emoji out of Swift for
good. **(2) Tasteful gamification:** within the warm, minimalist Claude aesthetic
(cream + terracotta `#D97757`, hairline borders), we enrich the existing `ProgressRing` /
`XPBar` / `StreakPill` and add a small set of restrained, **Reduce-Motion-safe**
microinteractions and celebration visuals — an animated `StreakFlame`, a goal-ring "close"
moment, a one-shot `LevelUpCelebration`, achievement chips, and named haptic patterns — using
SwiftUI's iOS-17 `.symbolEffect` (which honors Reduce Motion for free) and `DesignSystem`
tokens only. The bar: **classy, not garish** — no rainbow badges, no slot-machine dopamine.
Everything ships with zero third-party dependencies.

## 2. Goals / Non-goals
- **Goals:**
  - **Eliminate keyboard emoji from Swift** (4 literals across 3 files today) and prevent
    regressions with a CI check + allowlist.
  - Define a **semantic icon policy**: `MangoSymbol` (named tokens → SF Symbol names) + an
    `Icon` view that bakes in Mango's default **weight, rendering mode, and size token**, so
    icons are consistent and theme-able from one place (the same way `Palette`/`Typo` own
    color/type today).
  - Provide a precise, exhaustive **emoji → icon replacement table** (file + line + emoji →
    token + symbol + treatment), plus a **symbol-name → token migration list** for the bare
    string literals already in the code.
  - **Enrich/define gamification components** as token-driven, Reduce-Motion-safe SwiftUI
    views with stable signatures: `ProgressRing` (+ completion pop), `XPBar` (+ gain pulse),
    `StreakFlame`, `LevelUpCelebration`, `AchievementChip`, and a `confettiBurst` that uses
    falling SF-Symbol shapes (no external lib), all behind a single "celebrate" entry point.
  - Add **named haptic patterns** to `Haptics` (`levelUp`, `streakExtend`, `goalComplete`,
    `achievement`) layered on the existing primitives.
  - **Respect Reduce Motion** everywhere: every animated component has a defined static
    fallback; celebrations degrade to a brief opacity fade or a static state, never nothing
    important is communicated by motion alone.
- **Non-goals:**
  - **No new gamification *mechanics*** — XP amounts, level curve, streak math, achievement
    catalog are unchanged (owned by `GamificationEngine`/`LevelCurve`/`StreakCalculator` and
    the future `[activities-and-rewards]` spec). This spec is **presentation only**.
  - **No new screens or navigation.** We touch existing views (`TodayView`, `AuthView`,
    `OnboardingFlow`) and the `DesignSystem/` + a small `Components/` set; we don't add tabs
    or routes.
  - **No leaderboards, leagues, or social** (that's `0021`).
  - **No full custom icon font / no asset-heavy illustration system.** At most one custom
    symbol (the mango mark) as an optional enhancement (Decision D-2); the default is curated
    SF Symbols only.
  - **No color-token changes** beyond *using* the existing `Palette.streak` / `Palette.xp` /
    semantic tokens; we don't introduce new brand colors.

## 3. Background & context
**Current state — icons.** SF Symbols are referenced as **bare string literals** at call
sites (e.g. `Image(systemName: "flame.fill")` in `Components.swift:153`, `systemImage: "map"`
in `TodayView.swift:94`, `"play.fill"` / `"book"` / `"quote.opening"` in `TodayView`,
`"apple.logo"` / `"globe"` / `"bell.badge"` in `AuthView`/`OnboardingFlow`). There is **no
central icon vocabulary** — the same concept can be `"map"` or `"map.fill"` in different
places, weights/rendering modes are never specified (so everything is default monochrome
regular), and nothing enforces consistency. A repo scan finds ~30 distinct symbol names in
use; the most common are `wand.and.stars` (×4), `books.vertical` (×4), `book`/`map`/`map.fill`
(×2–3 each).

**Current state — emoji.** Four keyboard-emoji literals live directly in SwiftUI `Text`:

| # | File:line | Literal | Context |
|---|---|---|---|
| 1 | `Features/Home/TodayView.swift:71` | `🎉` | `Text(doneToday >= goalUnits ? "Daily goal complete 🎉" : "Daily goal")` |
| 2 | `Features/Home/TodayView.swift:110` | `🌱` | `Text("You've finished every lesson here. 🌱")` |
| 3 | `Features/Auth/AuthView.swift:32` | `🥭` | `Text("🥭").font(.system(size: 72))` — app mark on the sign-in screen |
| 4 | `Features/Onboarding/OnboardingFlow.swift:58` | `🥭` | `Text("🥭").font(.system(size: 64))` — app mark on the welcome step |

(Verified by `grep -rnP '[\x{1F000}-\x{1FAFF}…]' ios/Mango --include='*.swift'`: **4 hits, 3
files**. No emoji exist elsewhere in Swift.) Emoji are a problem here because: they **render
inconsistently** across iOS versions and ignore Dynamic Type weight, they **don't pick up the
Palette tint** (the `🌱` is meant to read as "success" but renders full-color green
regardless of theme/dark mode), they **clash with the restrained editorial aesthetic**, and
they are the textbook "garish gamification" signal this product explicitly avoids. The mango
mark as an emoji is especially fragile — it's the brand, rendered by whatever the OS font
vendor decided.

**Current state — gamification visuals.** `Components.swift` already has the right *bones*:
`ProgressRing` (animated trim, Reduce-Motion aware — line 105–117), `XPBar` (animated fill,
Reduce-Motion aware — line 122–145), and `StreakPill` (static `flame.fill` — line 149–162).
`TodayView` composes the ring into a daily-goal card. What's missing is **delight at the
moments that matter**: closing the daily ring, gaining XP, extending a streak, leveling up,
unlocking an achievement. Those moments currently pass silently (or with a bare `🎉`).
`Haptics.swift` has primitives (`tap`/`soft`/`rigid`/`success`/`warning`/`selection`) but no
semantic "level up" / "goal complete" patterns. The sibling spec `0008` §5 explicitly asks
that checkpoints and state controls "feel **gamified and celebratory** … not utilitarian," and
this spec supplies the shared vocabulary those features (and `0010`, `0011`) will reuse.

**Why now.** `0008` reframes the product around *doing* (activities + journey), which makes
the **feedback loop the product** — the ring closing, the streak extending, the level-up are
where motivation lives. Doing them *tastefully* is a brand-defining detail, and doing them
*consistently* requires the icon + component vocabulary this spec defines. iOS 17's
`.symbolEffect` makes most of this nearly free and **automatically Reduce-Motion-safe**
(see §12), so we can be expressive without an animation framework or a third-party lib.

**Design constraints (hard).** From `CLAUDE.md` / `0008`: **zero third-party iOS deps**
(SPM/CocoaPods-free); **all** color/spacing/type/icons via `DesignSystem` tokens (no hardcoded
hex or magic numbers; the existing `check_theme.sh` enforces the color half); **Reduce Motion
must be respected**; warm cream+terracotta minimalism retained; iOS 17+; Xcode 16
file-system-synchronized groups (new files under `ios/Mango/` auto-register — never hand-edit
`project.pbxproj`).

## 4. User stories
- As a **user closing my daily goal**, the ring fills and gives a single satisfying *pop* +
  haptic — a small, classy moment, not a confetti explosion every time.
- As a **user who just leveled up**, I get one tasteful full-screen-ish celebration (a calm
  burst of terracotta-tinted sparks behind my new level number) that I can **tap to dismiss**,
  and that becomes a quiet opacity fade if I have Reduce Motion on.
- As a **user extending a streak**, the flame gives a brief lively flicker + a distinct
  haptic, so the streak feels alive without being loud.
- As a **VoiceOver / Reduce-Motion / Dynamic-Type user**, every icon has a label, no
  information is conveyed by motion or color alone, and celebrations never trap me in
  animation — they're dismissible and degrade gracefully.
- As a **developer**, I write `Icon(.streak)` / `MangoSymbol.xp` instead of remembering
  `"flame.fill"` / `"bolt.fill"`, and CI stops me if I paste an emoji into Swift.
- As a **designer/brand owner**, the app reads as one coherent, warm, editorial system —
  consistent icon weights and tints, no stray full-color emoji breaking the palette.

## 5. Requirements
### Functional
- **FR-1 (semantic icon vocabulary).** Add `MangoSymbol` (enum of semantic tokens → SF Symbol
  names) and an `Icon` view in `DesignSystem/` (see §6.1–6.2). `Icon` applies Mango's default
  weight, rendering mode, and an **`IconSize`** token; callers pass a token, not a string.
- **FR-2 (icon policy).** Document and enforce by convention: **filled** variants for selected
  / emphasized / "achievement" states, **outline** for default/inactive; **monochrome**
  rendering tinted via `Palette` is the default; **hierarchical** allowed for richer single-
  tint icons; **multicolor is disallowed** in app chrome (it breaks the palette) except inside
  an explicit celebration. Default weight `.semibold` to match `Typo` UI weight; size from
  `IconSize` tokens, never a magic `font(.system(size:))`.
- **FR-3 (remove all keyboard emoji).** Replace the 4 emoji literals per the §6.3 table. After
  this, **zero** keyboard-emoji literals exist in `ios/**/*.swift`.
- **FR-4 (mango mark).** Replace the `🥭` app-mark emoji on `AuthView` and `OnboardingFlow`
  with a `MangoMark` view (default: an SF Symbol composed inside a terracotta "stamp" — see
  §6.4 / D-2). No `Text("🥭")` anywhere.
- **FR-5 (enrich gamification components).** Define stable SwiftUI signatures (§6.5) for:
  `ProgressRing` (add optional completion pop), `XPBar` (add optional gain pulse),
  `StreakFlame` (new, animatable), `LevelUpCelebration` (new, one-shot, dismissible),
  `AchievementChip` (new), and a `ConfettiBurst` / `.celebrate(_:)` overlay using falling
  SF-Symbol shapes (no third-party). `StreakPill` is refactored to embed `StreakFlame`.
- **FR-6 (haptic patterns).** Extend `Haptics` with semantic patterns `levelUp`,
  `streakExtend`, `goalComplete`, `achievement`, composed from existing generators (§6.6).
- **FR-7 (Reduce-Motion fallbacks).** Every animated component reads
  `@Environment(\.accessibilityReduceMotion)` (or relies on `.symbolEffect`'s built-in
  honoring) and defines an explicit static/opacity fallback. Celebrations are **tap-to-
  dismiss** and auto-dismiss on a timer.
- **FR-8 (CI guard).** Add `ios/scripts/check_no_emoji.sh` (mirroring `check_theme.sh`) that
  fails the build if a keyboard-emoji literal appears in `Mango/**/*.swift`, with an
  **allowlist** mechanism. Wire it into `make` / the iOS CI workflow alongside the theme check.
- **FR-9 (token-only).** All new UI uses `Palette`/`Typo`/`Metrics`/`IconSize`/`Haptics` — no
  hardcoded hex, no magic numbers, no bare symbol strings outside `MangoSymbol`. `check_theme.sh`
  must still pass.

### Non-functional
- **NFR-1 (no third-party deps).** Pure SwiftUI + SF Symbols + Core Haptics/UIKit feedback.
  Confetti is hand-rolled from SF-Symbol shapes; **no `ConfettiSwiftUI` or similar**.
- **NFR-2 (performance).** Prefer `.symbolEffect` (GPU, ~free) over hand-animated paths.
  Celebrations cap particle count (≤ ~18) and lifetime (≤ ~1.6 s) and never run in a tight
  layout loop. No celebration on a scroll/tab that re-renders frequently.
- **NFR-3 (accessibility).** Every `Icon` exposes an accessibility label (or is explicitly
  `.accessibilityHidden(true)` when purely decorative beside text). Color is never the sole
  signal (icon + label always paired — already a `Palette` convention). Dynamic Type via
  `Typo`; `IconSize` tokens scale where adjacent to text.
- **NFR-4 (theming).** Light/dark correct (use adaptive `Palette` tokens; `Palette.streak` and
  `Palette.xp` already adapt). No raw `.white`/`.black` outside `DesignSystem` (enforced).
- **NFR-5 (taste bar).** Celebrations are **rare and proportional**: level-up = big-ish but
  calm; daily-goal close = medium; XP gain / streak extend = micro. No celebration fires more
  than once per triggering event; none auto-repeats.

## 6. Design

### 6.1 `MangoSymbol` — semantic icon tokens
New file `ios/Mango/DesignSystem/Icons.swift`. A semantic enum mapping Mango concepts to SF
Symbol names so call sites never hardcode strings. Names chosen to match the symbols **already
in use** (so this is a consolidation, not a re-draw).

```swift
import SwiftUI

/// Semantic icon vocabulary. Call sites reference a concept (`.streak`), never a raw
/// SF Symbol string — the one place icon names live, mirroring how `Palette` owns color.
enum MangoSymbol: String {
    // Gamification
    case streak          = "flame.fill"            // streak / on a roll
    case xp              = "bolt.fill"             // XP / energy  (NEW vocab; replaces ad-hoc)
    case level           = "star.fill"             // level / rank
    case levelUp         = "sparkles"              // level-up celebration accent
    case goal            = "target"                // daily goal
    case goalComplete    = "checkmark.seal.fill"   // goal / journey complete
    case achievement     = "rosette"               // achievement / badge (calm, not a trophy)
    case sprout          = "leaf.fill"             // growth / "you finished everything" (was 🌱)
    case celebrate       = "party.popper.fill"     // generic celebrate accent (was 🎉)

    // Journey / content
    case journey         = "map.fill"
    case lesson          = "checklist"
    case book            = "book.fill"
    case bookOutline     = "book"
    case library         = "books.vertical.fill"
    case insight         = "quote.opening"
    case generate        = "wand.and.stars"        // AI generation
    case play            = "play.fill"
    case bookmark        = "bookmark.fill"

    // Navigation / chrome
    case profile         = "person.crop.circle"
    case settings        = "gearshape.fill"
    case reminder        = "bell.badge"
    case add             = "plus"
    case chevron         = "chevron.right"
    case check           = "checkmark.circle.fill"
    case circle          = "circle"

    // Auth / providers (kept as-is; brand glyphs)
    case apple           = "apple.logo"
    case google          = "globe"                 // Cognito Hosted UI brand-neutral
    case backend         = "antenna.radiowaves.left.and.right"

    var name: String { rawValue }
}
```

> Notes: `.xp` standardizes on `bolt.fill` (energy) — pick one and use it everywhere XP shows.
> `.achievement` uses `rosette` (a calm award glyph) rather than `trophy.fill` to stay classy
> (Decision D-3). Filled vs outline pairs (`book`/`bookOutline`, `check`/`circle`) support the
> selected-vs-default policy (FR-2).

### 6.2 `Icon` view + `IconSize` tokens
Same file. `Icon` is the **only** sanctioned way to render a `MangoSymbol`; it bakes in
default weight + rendering mode + size token and a sensible default accessibility behavior.

```swift
/// Sizing tokens for icons (kept distinct from `Metrics` spacing). Relative names so we
/// can tune the scale in one place.
enum IconSize {
    static let xs: CGFloat   = 12
    static let s: CGFloat    = 16
    static let m: CGFloat    = 20   // default inline / button glyph
    static let l: CGFloat    = 28
    static let xl: CGFloat   = 38   // empty-state / hero
    static let mark: CGFloat = 64   // app-mark stamp
}

enum IconRendering { case monochrome, hierarchical }

struct Icon: View {
    let symbol: MangoSymbol
    var size: CGFloat = IconSize.m
    var weight: Font.Weight = .semibold
    var rendering: IconRendering = .monochrome
    var tint: Color = Palette.textPrimary
    /// VoiceOver label; pass nil for decorative icons that sit next to descriptive text.
    var accessibilityLabel: String? = nil

    init(_ symbol: MangoSymbol,
         size: CGFloat = IconSize.m,
         weight: Font.Weight = .semibold,
         rendering: IconRendering = .monochrome,
         tint: Color = Palette.textPrimary,
         accessibilityLabel: String? = nil) {
        self.symbol = symbol; self.size = size; self.weight = weight
        self.rendering = rendering; self.tint = tint
        self.accessibilityLabel = accessibilityLabel
    }

    var body: some View {
        let img = Image(systemName: symbol.name)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(tint)
            .modifier(RenderingModifier(rendering: rendering))
        Group {
            if let accessibilityLabel {
                img.accessibilityLabel(Text(accessibilityLabel))
            } else {
                img.accessibilityHidden(true)   // decorative beside text by default
            }
        }
    }
}

private struct RenderingModifier: ViewModifier {
    let rendering: IconRendering
    func body(content: Content) -> some View {
        switch rendering {
        case .monochrome:   content.symbolRenderingMode(.monochrome)
        case .hierarchical: content.symbolRenderingMode(.hierarchical)
        }
    }
}
```

**Icon policy (FR-2), summarized for reviewers/docs:**
- **Rendering:** monochrome (Palette-tinted) by default; hierarchical for depth on a single
  tint; **multicolor/palette only inside a celebration**, never in chrome.
- **Weight:** `.semibold` default (matches UI type); `.bold` for emphasized/streak; `.regular`
  only for large hero/empty-state glyphs.
- **Fill vs outline:** filled = active/selected/achieved; outline = default/inactive
  (`book` vs `bookOutline`, `circle` vs `check`).
- **Size:** always an `IconSize` token. Inline-with-text icons should use `size` near the text
  cap height (≈`IconSize.s`/`.m`) and scale with Dynamic Type where they sit beside `Typo` text.
- **Existing `Tag` / `StreakPill` / `EmptyStateView`** keep accepting an SF-Symbol string for
  source-compat, but their internal defaults and all *new* call sites use `MangoSymbol.name`
  (migration list §6.7). Long-term, add `Tag(_, symbol: MangoSymbol)` convenience inits.

### 6.3 Emoji → icon replacement table (exhaustive — FR-3)
Every current keyboard-emoji usage and its theme-icon replacement. (Line numbers are current;
re-grep before editing.)

| # | File:line | Current | Replacement (concrete) | Treatment |
|---|---|---|---|---|
| 1 | `Features/Home/TodayView.swift:71` | `Text(... "Daily goal complete 🎉" ...)` | Drop the emoji from the string; render the **completion state via the ring pop + a small accent icon**. Title becomes plain `"Daily goal complete"`; place `Icon(.goalComplete, size: .s, tint: Palette.success, accessibilityLabel: "Complete")` **before** the title in the card header, shown only when `doneToday >= goalUnits`. | Static icon + (non-RM) one-shot ring pop (§6.5). |
| 2 | `Features/Home/TodayView.swift:110` | `Text("You've finished every lesson here. 🌱")` | Plain text `"You've finished every lesson here."` preceded by `Icon(.sprout, size: .s, tint: Palette.success, accessibilityLabel: "Finished")` in an `HStack`. | Static; sprout = growth metaphor, now Palette-tinted + dark-mode correct. |
| 3 | `Features/Auth/AuthView.swift:32` | `Text("🥭").font(.system(size: 72))` | `MangoMark(size: IconSize.mark)` (§6.4). | Static (no entrance animation on auth). |
| 4 | `Features/Onboarding/OnboardingFlow.swift:58` | `Text("🥭").font(.system(size: 64))` | `MangoMark(size: IconSize.mark)` | Optional gentle `.symbolEffect(.bounce, options: .nonRepeating)` on appear of the welcome step (auto-skips under Reduce Motion); otherwise static. |

After these four edits, `check_no_emoji.sh` (§6.8) passes with an empty allowlist.

### 6.4 `MangoMark` — the brand glyph (replaces `🥭`)
New file `ios/Mango/DesignSystem/MangoMark.swift`. Default implementation composes an SF Symbol
inside a terracotta rounded "stamp" so we own the brand mark instead of relying on the OS emoji
font. Two options (Decision D-2):

- **(A) Recommended for v1 — SF-Symbol stamp.** A filled rounded square in `Palette.accent`
  with a white `leaf.fill` (or `seal.fill`) glyph centered. Fully theme-able, no asset, no emoji.
  ```swift
  struct MangoMark: View {
      var size: CGFloat = IconSize.mark
      var body: some View {
          RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
              .fill(Palette.accent)
              .frame(width: size, height: size)
              .overlay(
                  Image(systemName: "leaf.fill")
                      .font(.system(size: size * 0.5, weight: .bold))
                      .foregroundStyle(Palette.onAccent)
              )
              .accessibilityElement()
              .accessibilityLabel("Mango")
      }
  }
  ```
- **(B) Custom SF Symbol (`mango.svg` → `.symbol`).** Author a real custom symbol from the
  three required templates (Ultralight/Regular/Black per Apple's variable template) and ship it
  in `Assets.xcassets` as a Symbol Image; reference via `Image("mango.symbol")`. Gives a true
  mango silhouette that inherits weight/rendering like any SF Symbol. **Heavier** (needs the
  template authored) and out of scope to *author* here — reserve as a follow-up; (A) ships now.

**Recommendation: (A)** for v1; note (B) as a polish task. Either way the public API is
`MangoMark(size:)`, so swapping the internal implementation later changes no call sites.

### 6.5 Gamification components (signatures + animation/fallback)
All in `ios/Mango/DesignSystem/Components.swift` (or a new `Components/Gamification.swift` under
`DesignSystem/`; both auto-register). Each lists its SwiftUI signature and the exact
`.symbolEffect`/animation + the Reduce-Motion fallback.

**(a) `ProgressRing` — enrich with a completion pop.** Keep the current API; add an optional
`celebrateOnComplete` flag and an internal one-shot scale pop when `progress` crosses 1.0.
```swift
struct ProgressRing: View {
    var progress: Double
    var size: CGFloat = 64
    var lineWidth: CGFloat = 9
    var tint: Color = Palette.accent
    var celebrateOnComplete: Bool = false           // NEW
    // ...existing body...
    // When progress reaches 1 and celebrateOnComplete && !reduceMotion:
    //   .scaleEffect(pop ? 1.06 : 1).animation(.spring(response: 0.35, dampingFraction: 0.5), value: pop)
    //   trigger pop via .onChange(of: progress >= 1) and Haptics.goalComplete()
    // Reduce Motion: no pop; ring simply shows full (progress already animated-or-not as today).
}
```

**(b) `XPBar` — enrich with a gain pulse.** Keep the current API; add an optional accent pulse
on increase.
```swift
struct XPBar: View {
    var value: Int
    var goal: Int
    var tint: Color = Palette.xp
    var height: CGFloat = 10
    var pulseOnGain: Bool = false                   // NEW
    // On value increase && !reduceMotion: briefly raise fill brightness / overlay a moving
    // highlight Capsule for ~0.4s. Reduce Motion: fill just updates (animation already gated).
}
```

**(c) `StreakFlame` — new, animatable flame.** Extract the flame so the streak can come alive.
```swift
struct StreakFlame: View {
    var days: Int
    var size: CGFloat = IconSize.m
    var active: Bool = true                          // dim when streak is 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Icon(.streak, size: size, weight: .bold,
             rendering: .hierarchical,
             tint: active ? Palette.streak : Palette.textTertiary)
            // Ambient life while active (indefinite, subtle):
            .symbolEffect(.pulse, options: .repeating, isActive: active && !reduceMotion)
            .accessibilityLabel("\(days) day streak")
    }
    /// Call when a streak extends to play a one-shot bounce:
    /// expose a `@State trigger` + `.symbolEffect(.bounce, value: trigger)` on the parent.
}
```
- **Extend moment:** parent flips a `bounceTrigger` and `.symbolEffect(.bounce, value:)` fires a
  single bounce + `Haptics.streakExtend()`. `.symbolEffect` **auto-honors Reduce Motion**, so no
  manual guard is needed for the bounce; the ambient `.pulse` is gated by `!reduceMotion`.
- **`StreakPill`** is refactored to embed `StreakFlame` instead of a static `flame.fill`
  (preserves its public API and accessibility label).

**(d) `LevelUpCelebration` — new, one-shot, dismissible.** A calm overlay: the new level number
in `Typo.display`, `Icon(.levelUp)` sparkles behind it, an optional `ConfettiBurst`, terracotta
on cream. Presented over the current screen; **tap-to-dismiss** + auto-dismiss timer.
```swift
struct LevelUpCelebration: View {
    let newLevel: Int
    let title: String                 // e.g. levelTitle
    var onDismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Body: dimmed scrim (Palette.background.opacity), centered Card with:
    //   Icon(.levelUp, size: .xl, rendering: .hierarchical, tint: Palette.accent)
    //       .symbolEffect(.bounce, options: .nonRepeating)          // auto RM-safe
    //   Text("Level \(newLevel)").font(Typo.display)
    //   Text(title).font(Typo.title3).foregroundStyle(Palette.textSecondary)
    //   ConfettiBurst(isActive: !reduceMotion)                       // §(f)
    // Appears with .opacity/.scale transition (reduceMotion -> .opacity only).
    // .onTapGesture { onDismiss() }; .task { try? await Task.sleep(2.2s); onDismiss() }
    // Fires Haptics.levelUp() once on appear.
}
```
- **Reduce Motion:** no scale/confetti; a plain opacity fade-in of the same card; still
  tap/auto dismiss. (Meaning is in the text + haptic, never the motion.)
- **Presentation helper:** a `.celebrateLevelUp(_:)` view modifier or an `@State` in the host
  view (e.g. `TodayView`/profile) that shows it when `GamificationEngine` reports a level
  increase. Wiring the *trigger* is left to the consuming feature (this spec defines the view).

**(e) `AchievementChip` — new.** A small, calm pill for an unlocked achievement (used in
profile/achievement surfaces; not garish).
```swift
struct AchievementChip: View {
    let title: String
    var symbol: MangoSymbol = .achievement
    var unlocked: Bool = true
    // HStack { Icon(symbol, size: .s, tint: unlocked ? Palette.accent : Palette.textTertiary)
    //          Text(title).font(.caption.weight(.semibold)) }
    // .padding(...).background((unlocked ? Palette.accent : Palette.textTertiary).opacity(0.14))
    // .clipShape(Capsule()); locked variant desaturated, no animation.
    // On unlock (parent-driven): .symbolEffect(.bounce, value: unlockTrigger) + Haptics.achievement()
}
```

**(f) `ConfettiBurst` / `.celebrate()` — new, no third-party.** Confetti from **falling
SF-Symbol shapes** (small `leaf.fill` / `sparkle` / `circle.fill`), tinted from a 2–3 color
**brand** set (terracotta + xp gold + success green), capped and short — the only place
multicolor is allowed.
```swift
struct ConfettiBurst: View {
    var isActive: Bool
    var requested: Int = 16                       // NFR-2 cap (≤18) applied via CelebrationMotion
    var symbols: [MangoSymbol] = [.sprout, .levelUp, .celebrate]
    var colors: [Color] = [Palette.accent, Palette.xp, Palette.success]
    var lifetime: Double = 1.6                    // NFR-2 ≤1.6s
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // One immutable piece; all randomness seeded once at build so layout is stable per appearance.
    private struct Piece: Identifiable {
        let id = UUID()
        let symbol: String; let color: Color
        let xFraction: CGFloat                     // 0…1 start x
        let delay: Double; let rotation: Double; let drift: CGFloat
    }

    @State private var pieces: [Piece] = []
    @State private var fall = false

    var body: some View {
        let n = CelebrationMotion.particleCount(reduceMotion: reduceMotion, requested: requested)
        GeometryReader { geo in
            if isActive && n > 0 {
                ZStack {
                    ForEach(pieces) { p in
                        Image(systemName: p.symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(p.color)
                            .rotationEffect(.degrees(fall ? p.rotation : 0))
                            .position(x: geo.size.width * p.xFraction + (fall ? p.drift : 0),
                                      y: fall ? geo.size.height + 24 : -24)
                            .opacity(fall ? 0 : 1)
                            .animation(.easeIn(duration: lifetime).delay(p.delay), value: fall)
                    }
                }
                .onAppear {
                    pieces = (0..<n).map { _ in
                        Piece(symbol: symbols.randomElement()!.name,
                              color: colors.randomElement()!,
                              xFraction: .random(in: 0.05...0.95),
                              delay: .random(in: 0...0.25),
                              rotation: .random(in: -220...220),
                              drift: .random(in: -40...40))
                    }
                    fall = true
                    // self-remove so it never lingers in the layout (NFR-2: no tight loop)
                    Task { try? await Task.sleep(for: .seconds(lifetime + 0.3)); pieces = [] }
                }
                .allowsHitTesting(false)
            }
        }
        .accessibilityHidden(true)                // decorative; meaning lives in text + haptic
    }
}
```
- Implementation uses only SwiftUI (`GeometryReader` + a fixed array of animated `Image`s) +
  `Foundation` randomness — **no external package** (NFR-1; explicitly *not* `ConfettiSwiftUI`).
  Reduce Motion ⇒ `particleCount == 0` ⇒ renders nothing (the level-up text + haptic carry the
  meaning). Particle count is capped and the burst self-removes after `lifetime`, satisfying NFR-2.

**(g) Reduce-Motion decision as a free, testable function.** So `ReduceMotionFallbackTests` (§8) can
assert the gating without instantiating a view, factor the decision out of every component into one
pure function in `DesignSystem/Components/Gamification.swift`:
```swift
/// Single source of truth for "should this celebration animate, and with how many particles."
/// Pure — no SwiftUI environment — so it is unit-testable like LevelCurve/StreakCalculator.
enum CelebrationMotion {
    /// Hand-animated paths (ring pop, XP pulse, confetti, scale transitions) run only when motion
    /// is allowed. `.symbolEffect`-based animations are NOT gated here — the system honors Reduce
    /// Motion for them automatically (see §12) — so callers pass `reduceMotion` straight to those.
    static func shouldAnimate(reduceMotion: Bool) -> Bool { !reduceMotion }

    /// Confetti particle count: capped at `cap` (≤18, NFR-2) when motion is allowed, else 0.
    static func particleCount(reduceMotion: Bool, requested: Int = 16, cap: Int = 18) -> Int {
        reduceMotion ? 0 : min(requested, cap)
    }
}
```
Every component above reads `CelebrationMotion.shouldAnimate(reduceMotion:)` for its hand-animated
branch and `ConfettiBurst` uses `particleCount(reduceMotion:requested:)`; `.symbolEffect` callers
gate the *ambient repeating* effects on `!reduceMotion` but leave one-shot `.bounce`/`.pulse`
ungated (the system stops them under Reduce Motion — verified, §12).

### 6.6 Haptic patterns (FR-6)
Extend `ios/Mango/DesignSystem/Haptics.swift` with **semantic** patterns built from the
existing generators (no Core Haptics `.ahap` needed for v1):
```swift
extension Haptics {
    /// Big, positive — a level-up. Soft "rise" then a success notification.
    static func levelUp() {
        soft()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { success() }
    }
    /// Streak extended — a single confident tap.
    static func streakExtend() { rigid() }
    /// Daily goal ring closed — success notification.
    static func goalComplete() { success() }
    /// Achievement unlocked — light double tap.
    static func achievement() {
        tap()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { tap() }
    }
}
```
- All are additive; existing call sites unaffected. Haptics already degrade safely on devices
  without a Taptic Engine. (System Haptics setting is respected by `UIFeedbackGenerator`.)

### 6.7 Symbol-string → token migration (icons cleanup, supporting FR-1/FR-9)
Not emoji, but part of "consistent semantic icons." Replace bare `systemName:`/`systemImage:`
strings at these call sites with `MangoSymbol` (via `Icon(...)` or by passing `.name` into the
existing `Tag`/`Label`). Representative (non-exhaustive — a quick grep enumerates the rest;
`grep -rnoE 'system(Name|Image): "[^"]+"' ios/Mango`):

| Call site | Current literal | Token |
|---|---|---|
| `Components.swift:153` (`StreakPill`) | `"flame.fill"` | `MangoSymbol.streak` (via `StreakFlame`) |
| `TodayView.swift:94` | `systemImage: "map"` | `.journey` (`map.fill`) |
| `TodayView.swift:101` | `systemImage: "play.fill"` | `.play` |
| `TodayView.swift:107` | `systemImage: "book"` | `.bookOutline` |
| `TodayView.swift:123` | `systemImage: "quote.opening"` | `.insight` |
| `TodayView.swift:31` | `systemImage: "books.vertical"` | `.library` (`books.vertical.fill`) or keep outline |
| `AuthView.swift:74` | `systemImage: "apple.logo"` | `.apple` |
| `AuthView.swift:82` | `systemImage: "globe"` | `.google` |
| `OnboardingFlow.swift:114` | `"checkmark.circle.fill"` / `"circle"` | `.check` / `.circle` |
| `OnboardingFlow.swift:139` | `systemImage: "bell.badge"` | `.reminder` |

> This migration is **mechanical and low-risk** but **secondary** to the emoji cleanup. It can
> land in the same PR or a fast follow; the acceptance criteria gate on emoji + the new
> components, and treat the string→token sweep as "all *new* code uses tokens; existing
> literals migrated opportunistically" (Decision D-4) to avoid a giant diff blocking the
> feature. A future lint could enforce "no bare `systemName:` outside `Icon.swift`."

### 6.8 CI guard — `ios/scripts/check_no_emoji.sh` (FR-8)
Mirror `check_theme.sh` exactly in style (bash, `set -euo pipefail`, `cd` to `ios/`, grep,
non-zero exit + ❌). Block any keyboard-emoji codepoint in `Mango/**/*.swift`, with an
**allowlist** file (`ios/scripts/emoji_allowlist.txt`, one `path:line` or substring per line)
for the rare sanctioned case (there are none today, so the allowlist ships empty).

```bash
#!/usr/bin/env bash
# Emoji audit — no keyboard emoji literals in Swift (use MangoSymbol / Icon instead).
#   BLOCK: any emoji / pictograph / regional-indicator codepoint in Mango/**/*.swift
# Allowlist: ios/scripts/emoji_allowlist.txt (substrings; lines matching are ignored).
# Run from anywhere: bash ios/scripts/check_no_emoji.sh
set -euo pipefail
cd "$(dirname "$0")/.."          # -> ios/
SRC="Mango"
ALLOW="scripts/emoji_allowlist.txt"
fail=0

# Emoji ranges: Misc Symbols/Dingbats, Misc Symbols & Pictographs, Emoticons, Transport,
# Supplemental Symbols & Pictographs/Symbols-Extended-A, regional indicators, VS-16.
PATTERN='[\x{2190}-\x{21FF}\x{2300}-\x{27BF}\x{2B00}-\x{2BFF}\x{1F000}-\x{1FAFF}\x{1F1E6}-\x{1F1FF}\x{FE0F}]'

hits=$(grep -rnP "$PATTERN" "$SRC" --include='*.swift' || true)

# Drop allowlisted lines (substring match), if the allowlist exists and is non-empty.
if [ -n "$hits" ] && [ -s "$ALLOW" ]; then
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    hits=$(printf '%s\n' "$hits" | grep -vF "$pat" || true)
  done < "$ALLOW"
fi

if [ -n "$hits" ]; then
  echo "❌ Keyboard emoji in Swift (use DesignSystem MangoSymbol/Icon, not emoji):"
  echo "$hits"
  echo "   If an emoji is truly intentional, add the 'path:line' substring to $ALLOW."
  fail=1
fi

[ "$fail" -eq 0 ] && echo "✓ emoji audit passed — no keyboard emoji in Swift"
exit $fail
```
- The shell script itself contains the ❌/✓ glyphs in `echo` strings (matching `check_theme.sh`)
  — those are **not** Swift, so they don't trip the check (the check only scans
  `Mango/**/*.swift`). The `PATTERN` deliberately spans arrows→symbols→pictographs→regional
  indicators + VS-16 so things like `️` (variation selectors) are caught.
- **Wiring:** add to the root `Makefile` (e.g. a `check-theme` / `check-icons` target that runs
  both scripts) and call it from `.github/workflows/ios-ci.yml` next to the existing theme audit
  so the gate runs on every PR. (The repo already runs `check_theme.sh` in CI; this slots in
  beside it.)

### 6.9 Files & where things live (Xcode 16 sync — auto-registered)
- **New:** `DesignSystem/Icons.swift` (`MangoSymbol`, `Icon`, `IconSize`, `IconRendering`),
  `DesignSystem/MangoMark.swift`, `DesignSystem/Components/Gamification.swift`
  (`StreakFlame`, `LevelUpCelebration`, `AchievementChip`, `ConfettiBurst`) — or fold the
  components into existing `DesignSystem/Components.swift`.
- **Edited:** `DesignSystem/Components.swift` (`ProgressRing`, `XPBar`, `StreakPill`),
  `DesignSystem/Haptics.swift` (patterns), `Features/Home/TodayView.swift`,
  `Features/Auth/AuthView.swift`, `Features/Onboarding/OnboardingFlow.swift`.
- **New (tooling):** `ios/scripts/check_no_emoji.sh`, `ios/scripts/emoji_allowlist.txt`
  (empty), `Makefile` target, `ios-ci.yml` step.
- **Tests:** `MangoTests/MangoSymbolTests.swift`, `MangoTests/ReduceMotionFallbackTests.swift`
  (see §8).

## 7. Acceptance criteria
- [ ] **AC-1 (no keyboard emoji):** `bash ios/scripts/check_no_emoji.sh` passes, and a repo
      grep `grep -rnP '[\x{1F000}-\x{1FAFF}…]' ios/Mango --include='*.swift'` returns **0**
      hits. The 4 known literals (§6.3) are gone. *(CI + grep.)*
- [ ] **AC-2 (emoji replaced semantically):** TodayView goal-complete + finished states render
      `Icon(.goalComplete)` / `Icon(.sprout)` (Palette-tinted, dark-mode correct); AuthView and
      OnboardingFlow render `MangoMark`. No `Text("…emoji…")` remains. *(Manual UI + dark-mode
      screenshot.)*
- [ ] **AC-3 (semantic icon vocabulary exists & is used):** `MangoSymbol`, `Icon`, `IconSize`
      compile; all *new* icon usages go through `Icon`/`MangoSymbol`; representative existing
      literals migrated per §6.7 (or a follow-up task filed). *(Code review + build.)*
- [ ] **AC-4 (icon policy honored):** default weight `.semibold`, monochrome Palette tint;
      filled-vs-outline used for active-vs-default; no `font(.system(size:))` magic numbers for
      icons (sizes from `IconSize`). *(Code review.)*
- [ ] **AC-5 (gamification components defined):** `ProgressRing` (completion pop), `XPBar` (gain
      pulse), `StreakFlame`, `LevelUpCelebration`, `AchievementChip`, `ConfettiBurst` exist with
      the §6.5 signatures and build; `StreakPill` uses `StreakFlame`. *(Build + previews.)*
- [ ] **AC-6 (Reduce Motion safe):** with **Reduce Motion ON**, `StreakFlame` ambient pulse is
      off, `ProgressRing` pop and `ConfettiBurst` particles do **not** play, `LevelUpCelebration`
      shows as an opacity fade and is still **tap/auto-dismissible**; no information is lost.
      *(Manual w/ Settings ▸ Accessibility ▸ Motion; `ReduceMotionFallbackTests` for the gated
      flags.)*
- [ ] **AC-7 (haptics):** `Haptics.levelUp/streakExtend/goalComplete/achievement` exist and are
      invoked by the matching components; existing haptic calls unchanged. *(Code review +
      device feel-test.)*
- [ ] **AC-8 (no third-party deps):** no SPM/CocoaPods entries added; confetti is hand-rolled.
      Project still builds by just opening it. *(Inspect project; build.)*
- [ ] **AC-9 (tokens only / theme audit green):** `bash ios/scripts/check_theme.sh` still passes;
      no raw hex, no raw `.white`/`.black` outside `DesignSystem/`. *(CI.)*
- [ ] **AC-10 (accessibility):** every decorative `Icon` is hidden or labeled; VoiceOver reads
      streak/goal/level meaningfully; Dynamic Type at XXL doesn't clip the goal card or chips.
      *(VoiceOver + Dynamic Type pass.)*

## 8. Test plan
- **Unit (automated, in `MangoTests`):**
  - `MangoSymbolTests` — every `MangoSymbol.name` is non-empty and (optionally) resolvable via
    `UIImage(systemName:)` so a typo'd symbol name fails CI (cheap correctness net for the
    vocabulary).
  - `ReduceMotionFallbackTests` — pure-logic assertions on `CelebrationMotion` (§6.5g):
    `shouldAnimate(reduceMotion: true) == false` / `… false) == true`;
    `particleCount(reduceMotion: true) == 0`; `particleCount(reduceMotion: false, requested: 30) == 18`
    (cap honored, NFR-2). Imports `@testable import Mango` only — no view instantiation — mirroring
    how `LevelCurve`/`StreakCalculator` are unit-tested.
- **Snapshot/preview (manual but systematic):** SwiftUI `#Preview`s for each component in
  **light + dark** and **Reduce-Motion on/off** (e.g. `.environment(\.accessibilityReduceMotion,
  true)`), plus Dynamic Type XXL. Visual review against the "classy, not garish" bar.
- **Manual device:** level-up celebration (tap-dismiss + auto-dismiss + haptic), streak extend
  bounce, daily-goal ring close pop, achievement unlock; confirm none fire repeatedly; confirm
  haptics feel proportional. Repeat with Reduce Motion ON to confirm graceful degradation.
- **CI:** `check_no_emoji.sh` and `check_theme.sh` both run in `ios-ci.yml`; `make ios-test`
  green. Add a deliberately-emoji'd throwaway line locally to confirm the guard **fails** (then
  remove).
- **Regression:** existing `LevelCurve`/`StreakCalculator`/DTO/TextStats tests untouched and
  green; `ProgressRing`/`XPBar` existing call sites still compile (API additions are optional
  params with defaults).

## 9. Rollout & migration
- **No data migration** — this is purely presentational; no models, no persistence, no API,
  no `openapi.yaml` change.
- **Flag (optional):** a lightweight `AppSettings.celebrationsEnabled` (default **on**) could
  gate the *celebration overlays* (level-up/confetti) for a calm-mode preference and easy A/B;
  the icon cleanup and component definitions ship unconditionally. (Decision D-5 — recommend
  shipping without a flag for v1 since each moment is already restrained and Reduce-Motion-safe;
  add the setting later if user research wants a "minimal effects" toggle.)
- **Sequencing:** land the **icon vocabulary + emoji cleanup + CI guard first** (small, safe,
  unblocks the guard), then the **gamification components** (consumed by `0008`/`0010`/`0011`).
  No teardown needed; additive throughout.
- **Backward compatibility:** all component API changes are additive optional parameters; the
  `Tag`/`StreakPill`/`EmptyStateView` string-based inits stay for source-compat.

## 10. Risks & open decisions
- **R-1 Gamification reads as garish / off-brand.** *Mitigation:* hard taste rules in §5
  (NFR-5): proportional, rare, monochrome-except-celebration, no auto-repeat; design review
  against light+dark previews; celebrations dismissible. Confetti is the only multicolor and is
  capped/short.
- **R-2 Motion causes discomfort / fails accessibility.** *Mitigation:* `.symbolEffect` honors
  Reduce Motion automatically; every hand-animated path explicitly checks
  `accessibilityReduceMotion`; celebrations are tap-to-dismiss with a static opacity fallback
  (Apple HIG: stylistic motion should stop under Reduce Motion; opacity fades are acceptable —
  §12).
- **R-3 CI guard false-positives/negatives.** *Mitigation:* the codepoint ranges are explicit
  and scoped to `Mango/**/*.swift`; an allowlist exists for true exceptions; the script's own
  ❌/✓ glyphs live in the *script*, not in scanned Swift. Validate against the 4 known hits
  before/after.
- **R-4 Custom mango symbol scope-creep.** *Mitigation:* default `MangoMark` (option A) needs
  **no** custom asset; the true custom SF Symbol (option B) is a reserved polish task, behind
  the same `MangoMark` API so it's a drop-in later.
- **R-5 String→token sweep balloons the diff.** *Mitigation:* D-4 — gate AC on emoji + new
  components; migrate existing symbol literals opportunistically / in a fast follow, not as a
  blocker.
- **Decisions needed (with recommendations):**
  - **D-1 (recommended: monochrome Palette-tinted default; multicolor only inside celebration).**
    Default rendering mode for app icons.
  - **D-2 (recommended: ship `MangoMark` option A — SF-Symbol stamp — now; author a custom
    `mango.symbol` (option B) as a follow-up).** How to render the brand mark without emoji.
  - **D-3 (recommended: `rosette` for achievements, not `trophy.fill`).** Achievement glyph that
    stays classy.
  - **D-4 (recommended: emoji cleanup + new tokens are the gate; migrate existing symbol-string
    literals opportunistically).** Scope of the string→token sweep.
  - **D-5 (recommended: ship celebrations without a flag for v1; add a `celebrationsEnabled`
    setting later if research wants a minimal-effects mode).** Whether to gate celebrations.
  - **D-6 (recommended: keep haptics as composed `UIFeedbackGenerator` patterns for v1; consider
    a single `.ahap` for the level-up later).** Haptic fidelity vs simplicity.

## 11. Tasks & estimate
1. `DesignSystem/Icons.swift` — `MangoSymbol`, `Icon`, `IconSize`, `IconRendering` + icon policy
   doc-comment. **(S)**
2. `MangoSymbolTests` (names non-empty / resolvable). **(S)**
3. `DesignSystem/MangoMark.swift` (option A). **(S)**
4. Emoji cleanup — edit `TodayView` (×2), `AuthView`, `OnboardingFlow` per §6.3 (icons + mark).
   **(S)**
5. `ios/scripts/check_no_emoji.sh` + empty `emoji_allowlist.txt`; wire into `Makefile` +
   `ios-ci.yml` beside `check_theme.sh`. **(S)**
6. Enrich `ProgressRing` (completion pop) + `XPBar` (gain pulse) with Reduce-Motion fallbacks.
   **(S)**
7. `StreakFlame` (+ refactor `StreakPill` to use it). **(S)**
8. `AchievementChip`. **(S)**
9. `ConfettiBurst` (hand-rolled, capped, Reduce-Motion → empty). **(M)**
10. `LevelUpCelebration` (one-shot, dismissible, RM opacity fallback) + a presentation helper.
    **(M)**
11. `Haptics` patterns (`levelUp`/`streakExtend`/`goalComplete`/`achievement`). **(S)**
12. `ReduceMotionFallbackTests` + factor the reduce-motion decision into a free function. **(S)**
13. Previews (light/dark, RM on/off, Dynamic Type XXL) for all components; design-review pass
    against the taste bar. **(M)**
14. *(Fast follow / optional)* String→token migration sweep (§6.7) across Features. **(M)**
15. *(Polish / optional)* Author custom `mango.symbol` (MangoMark option B). **(M)**

## 12. References
- **Repo (read for accuracy):** `CLAUDE.md` (invariants: no third-party deps, tokens-only,
  Reduce Motion, Xcode 16 sync groups); `working/0008-product-reframe-activity-first.md` (§5
  "feel gamified and celebratory"; activity-first framing); `docs/GAMIFICATION.md` (ethics —
  motivate, don't manipulate). iOS, **exact spots quoted in this spec:**
  `ios/Mango/DesignSystem/Theme.swift` (`Palette.streak` `#E8835A`, `Palette.xp`, semantic
  tokens; `Metrics`), `DesignSystem/Components.swift` (`ProgressRing` 105–117, `XPBar` 122–145,
  `StreakPill` 149–162, `Tag`, `EmptyStateView`), `DesignSystem/Typography.swift`,
  `DesignSystem/Haptics.swift`, `DesignSystem/Color+Hex.swift`;
  `Features/Home/TodayView.swift:71,110` (`🎉`, `🌱`),
  `Features/Auth/AuthView.swift:32` (`🥭`),
  `Features/Onboarding/OnboardingFlow.swift:58` (`🥭`);
  `ios/scripts/check_theme.sh` (the audit style mirrored by `check_no_emoji.sh`).
  **Finding:** exactly **4** keyboard-emoji literals across **3** files; ~30 distinct SF Symbol
  names used as bare strings with no central vocabulary.
- **Cross-spec:** `0008` (consumes these gamified components for checkpoints/state controls),
  `0010-onboarding-redesign` (welcome step uses `MangoMark`), `0011-navigation-and-activity-
  interaction` (activity cards reuse `ProgressRing`/chips), `0021-social-leagues` (future;
  out of scope here).
- **Research (web):**
  - **SF Symbols / `.symbolEffect` (iOS 17):** built-in effects (`.bounce`, `.pulse`,
    `.variableColor`, `.scale`, `.appear/.disappear`, `.replace`); discrete (one-shot) vs
    indefinite (repeating) behaviors; the modifier propagates down the hierarchy and can be
    removed with `.symbolEffectsRemoved`. — Apple WWDC23 "Animate symbols in your app":
    https://developer.apple.com/videos/play/wwdc2023/10258/ ; SF Symbols overview:
    https://developer.apple.com/sf-symbols/
  - **Rendering modes & weights:** monochrome / hierarchical / palette / multicolor; pick
    monochrome+tint for chrome, reserve multicolor for moments — Apple "Animate symbols" notes:
    https://wwdcnotes.com/documentation/wwdc23-10258-animate-symbols-in-your-app/ ; practical
    `.symbolEffect` usage: https://www.appcoda.com/swiftui-symboleffect/
  - **`.symbolEffect` honors Reduce Motion automatically & is GPU-cheap** (verified 2026-06): the
    framework reduces motion-heavy symbol effects under the system Reduce Motion setting **without
    per-app code**, so one-shot `.bounce`/`.pulse` need no manual `accessibilityReduceMotion` guard
    (only ambient *repeating* effects are gated, to avoid perpetual motion) — Symbol Effects
    vocabulary write-up: https://blakecrosley.com/blog/symbol-effects-vocabulary ;
    `.symbolEffect` usage: https://www.appcoda.com/swiftui-symboleffect/ ; effect list
    (`.bounce`/`.pulse`/`.variableColor`/`.scale`/`.appear`/`.disappear`): WWDC23 10258 (below)
  - **Tasteful gamification:** moderation/restraint, "natural extension not afterthought,"
    avoid manipulative dopamine loops; Apple Watch Activity Rings & Duolingo streaks as the
    canonical *calm* progress/streak patterns — Ethical Gamification in UX:
    https://medium.com/@gideonlyomu/avoiding-the-pitfalls-best-practices-and-ethical-gamification-in-ux-45ff3f2739ee ;
    UX gamification examples: https://uxcam.com/blog/gamification-examples-app-best-practices/
  - **Accessibility of motion/celebration (Apple HIG "Motion"):** make motion optional, don't
    convey meaning by motion alone; for stylistic/decorative motion, **stop it under Reduce
    Motion**; **opacity fades are acceptable** under Reduce Motion; make **longer celebrations
    dismissible by tap** —
    https://developer.apple.com/design/human-interface-guidelines/motion ; supporting Reduce
    Motion in SwiftUI:
    https://www.createwithswift.com/ensure-visual-accessibility-supporting-reduced-motion-preferences-in-swiftui/
  - **Custom SF Symbol (if MangoMark option B is pursued):** the variable template + the three
    required weight sources (Ultralight/Regular/Black) —
    https://blakecrosley.com/blog/custom-sf-symbols-creation
