# 0002 — Claude-consistent UI theme

- **Epic:** M2 · **Status:** Draft · **Updated:** 2026-06-25

## 1. Summary
Refine Mango's visual language so it reads unmistakably "Claude": warm cream
surfaces, a terracotta accent, editorial serif display type, generous whitespace, and
calm motion — applied consistently across every screen, in light and dark, accessibly.

## 2. Goals / Non-goals
- **Goals:** token-only styling; palette/typography matched to Claude's product feel;
  unified components; tasteful motion; AA contrast + Dynamic Type + colorblind-safe;
  captured in `DESIGN_SYSTEM.md`.
- **Non-goals:** new features/screens; logo/brand redesign; marketing site.

## 3. Background
Tokens already exist in `DesignSystem/Theme.swift` (`Palette`, `Metrics`, `Typo`).
This epic tightens values and enforces consistency; it is pure front-end.

## 4. User stories
- As a user, the app feels calm and premium, like Claude.
- As a developer, I never hardcode a color or spacing value.

## 5. Requirements
- **FR-1** No literal hex/spacing outside `DesignSystem/` (enforced by a grep audit).
- **FR-2** Palette tuned to Claude (light → dark): bg `#FAF9F5`→`#1F1E1D`,
  surface `#FFFFFF`→`#262624`, ink `#1F1E1D`→`#ECEAE3`, secondary text, borders
  `#E7E5DB`→`#3A3A36`, accent `#D97757` (pressed `#C15F3C`), plus semantic
  success/info/warning/danger that stay colorblind-distinct.
- **FR-3** Type: serif (New York) for display/titles, SF Pro for body/UI; consistent
  scale; everything relative to Dynamic Type text styles.
- **FR-4** Components unified: `Card` (radius 18), primary/secondary buttons, `Tag`,
  `ProgressRing`, `XPBar`, `StreakPill`, list rows, section headers, and empty/
  loading/error states.
- **FR-5** Motion: one spring for transitions; XP tick via `.contentTransition(.numericText())`;
  node-unlock via `PhaseAnimator`; honor **Reduce Motion**.
- **FR-6** Full dark-mode parity; refined `AppIcon`.
- **NFR:** AA contrast (≥4.5 for text), meaning never conveyed by color alone (icon +
  label), no scroll-perf regressions.

## 6. Design
A token table (light/dark hex) + type table in `DESIGN_SYSTEM.md`, then a per-screen
pass: Onboarding, Today, Library, AddBook, BookDetail, Reader, Journey, Lesson,
Profile, Settings. Components changed in `DesignSystem/Components.swift`; tokens in
`Theme.swift`/`Typography.swift`.

## 7. Acceptance criteria
- [ ] `grep -rE "#[0-9A-Fa-f]{6}"` finds matches only under `DesignSystem/`.
- [ ] Text tokens pass AA (≥4.5) in light and dark (documented).
- [ ] Dynamic Type XXL: no clipping on any screen.
- [ ] Reduce Motion disables the celebratory animations gracefully.
- [ ] `DESIGN_SYSTEM.md` lists final tokens + do/don't; design review signs off.

## 8. Test plan
Token-audit script (grep) in CI (warn); manual matrix on Simulator (light/dark ×
default/XXL Dynamic Type); optional snapshot tests for key components.

## 9. Rollout
Single front-end PR; no flags; no migration.

## 10. Risks & open decisions
- Claude hex values are research approximations — confirm against the current Claude
  app. **Decision:** use Apple's New York serif (zero-dep) vs bundling a custom serif
  → **recommend New York**.

## 11. Tasks
1. Token audit + grep guard (S). 2. Palette tune + contrast check (S). 3. Type pass (S).
4. Component pass (M). 5. Motion + reduce-motion (S). 6. Dark-mode + icon (S).
7. Update `DESIGN_SYSTEM.md` (S). — overall **M**.

## 12. References
`DesignSystem/Theme.swift`, [../DESIGN_SYSTEM.md](../DESIGN_SYSTEM.md), [../ROADMAP.md](../ROADMAP.md) M2.
