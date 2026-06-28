# 0012 — App icon redesign (mango-in-spark mark)

- **Epic:** M11 · **Status:** Draft · **Owner:** unassigned · **Updated:** 2026-06-28
- **Reviewers:** Principal, SD, QA

## 1. Summary
Replace Mango's current single-PNG app icon with a **warm, minimal "spark/burst"
mark** — an **original** friendly radiating motif (Claude-like *in spirit*, never a
copy of Anthropic's logo) with a **literal mango silhouette** (body + a single leaf)
centered inside it, in place of any letter "m". The icon sits on a soft cream→terracotta
radial background and reads cleanly from **40 px home-screen size up to the 1024 px App
Store master**. We ship the iOS 18 **light / dark / tinted** appearance variants in the
`AppIcon.appiconset` and (recommended) an iOS 26 **Icon Composer** layered version for
the Liquid Glass treatment, all derived from one vector source. This spec is a **plan**:
it specifies the concept, exact geometry, palette, and asset pipeline precisely enough
that a designer **or** a generation step (the `canvas-design` skill / a vector tool) can
produce the final art during implementation — no app code logic changes, only assets +
`Contents.json`.

## 2. Goals / Non-goals
- **Goals:**
  - A **distinct, on-brand** app icon: an **original radial spark/burst** enclosing a
    **literal mango silhouette** (fruit body + leaf), not a letterform, not a replica of
    any existing logo.
  - **On-brand palette only** — cream + terracotta from `DesignSystem` (`#FAF9F5` ground
    → `#D97757`/`#C15F3C` terracotta; charcoal `#1F1E1D` for max-contrast detail). Two to
    three colors total.
  - **Legible at all sizes** — crisp and recognizable from **40–60 px** (home screen /
    Spotlight) through **1024 px** (App Store), surviving Apple's automatic squircle mask.
  - **iOS-compliant master**: single **1024×1024** PNG, **fully opaque (no alpha)**,
    **sRGB**, square, corners **not** pre-rounded.
  - **iOS 18 appearance variants** present in `Contents.json`: **light** (Any), **dark**,
    and **tinted** (grayscale) — authored from the same source so the mark stays
    recognizable across Default / Dark / Tinted.
  - **Producible from one vector source** — a documented SVG construction (shapes,
    coordinates, petal count, corner radii) that exports the 1024 master and each variant
    deterministically.
  - **Original / non-infringing** — explicitly an inspired-by, geometrically-original mark
    (see §5 NF and §10 D-Legal). Trademark-safe.
- **Non-goals:**
  - **Final pixels** — this spec does not commit the exact production PNGs; it defines the
    concept + geometry + pipeline. Final art is produced in implementation and reviewed.
  - **In-app brand/logo usage** (splash, onboarding hero, marketing) — out of scope here;
    those may *reuse* the resulting vector but their placement/sizing is separate (touches
    `0010` onboarding, which consumes named icons, and `0013` theme-icon set).
  - **Alternate / seasonal app icons** (user-selectable `CFBundleAlternateIcons`) — a
    possible future follow-up, noted in §9, not built here.
  - **AccentColor** changes — `AccentColor` asset stays `#D97757`; unchanged.
  - **Renaming** the icon asset or build-setting key (`ASSETCATALOG_COMPILER_APPICON_NAME`
    stays `AppIcon`).

## 3. Background & context
**Current state** (verified):
- `ios/Mango/Resources/Assets.xcassets/AppIcon.appiconset/` contains **one image**,
  `AppIcon.png`, plus `Contents.json`. The PNG is **1024×1024, 8-bit RGB, non-interlaced,
  color-type 2 (truecolor, no alpha)** — i.e. already opaque and the correct master size.
- `Contents.json` declares a **single universal iOS 1024×1024 image** (the modern Xcode
  "single size" form) with **no dark/tinted entries**:
  ```json
  { "images": [ { "filename": "AppIcon.png", "idiom": "universal",
                  "platform": "ios", "size": "1024x1024" } ],
    "info": { "author": "xcode", "version": 1 } }
  ```
- The project references the set via **`ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`** in
  `ios/project.yml` (XcodeGen base settings); accent via
  `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor`. New Swift/asset files
  under `ios/Mango/` are picked up by Xcode 16 file-system-synchronized groups — but
  **asset-catalog contents are edited directly** (add files + edit `Contents.json`); do
  **not** hand-edit `project.pbxproj` (CLAUDE.md invariant).

**Brand palette** (single source of truth — `ios/Mango/DesignSystem/Theme.swift`, with
the `Color(hex:)` initializer in `Color+Hex.swift`):
| Token | Hex | Role in icon |
|---|---|---|
| `Palette.terracotta` (`accent`) | `#D97757` | primary spark + mango body |
| `Palette.terracottaDeep` (`accentPressed`) | `#C15F3C` | deep edge of radial ground / shading |
| `Palette.background` (light) | `#FAF9F5` | cream center of radial ground |
| `Palette.surface` (light) | `#FFFFFF` | optional inner highlight |
| `Palette.textPrimary` (light) | `#1F1E1D` | charcoal — leaf vein / silhouette accent |
| `Palette.background` (dark) | `#1A1A18` | dark-variant ground |
| `Palette.surface` (dark) | `#262624` | dark-variant ground (alt) |
| `Palette.textPrimary` (dark) | `#ECEAE3` | dark-variant foreground tint |
| `Palette.streak` | `#E8835A` | optional warm mid-tone in the burst gradient |

Mango's visual language (per `Theme.swift` header and `0002-claude-ui-theme.md`): "warm,
calm, Claude-like: cream surfaces, a terracotta accent, generous whitespace, soft rounded
shapes." The icon must express that — **warm minimalism**, not a glossy or skeuomorphic
fruit illustration.

**Why now:** M11 is the "first impression" epic (pairs with `0010` onboarding redesign and
`0013` theme icons / emoji removal). The current icon is a placeholder; a deliberate,
original mark makes Mango feel finished and recognizable on the home screen, and gives the
brand a reusable vector.

**Related specs/docs:** `0002-claude-ui-theme.md` (tokens/palette), `0010-onboarding-
redesign.md` (consumes brand imagery; "no emoji"), `0013-…-theme-icons.md` (in-app icon
set), `0022-app-store-prep.md` (store listing assets — the 1024 master feeds the listing),
`docs/DESIGN_SYSTEM.md`.

## 4. User stories
- As a **user scanning my home screen**, I want Mango's icon to be **instantly
  recognizable and visually distinct**, so that I can find and tap it without reading a
  label.
- As a **prospective user in the App Store**, I want the icon to look **polished, warm, and
  trustworthy at thumbnail size**, so that it signals a quality, friendly product.
- As an **iOS 18+ user** who uses **Dark Mode or a tinted home screen**, I want the icon to
  **look intentional in dark and tinted appearances**, so that it matches my setup instead
  of looking like a bright sticker.
- As the **Mango brand owner**, I want an **original mark** that is *inspired by* a friendly
  radial spark but **does not copy Anthropic's Claude logo/trademark**, so that we are
  legally and ethically safe.
- As a **designer or build step implementing this**, I want **exact geometry, coordinates,
  and color hex**, so that I can reproduce the icon deterministically from a vector source
  and export every required asset.

## 5. Requirements
### Functional (testable)
- **FR-1 — Mark concept.** The icon depicts an **original radiating spark/burst** with a
  **literal mango silhouette inside it**: a rounded mango **body** with a small **leaf** at
  the top. **No letterform** ("m" or otherwise) and **no text** anywhere in the icon.
- **FR-2 — Palette.** Only brand colors are used, drawn from `DesignSystem` (§3 table):
  cream ground (`#FAF9F5`), terracotta family (`#D97757`/`#C15F3C`, optional `#E8835A`),
  and charcoal (`#1F1E1D`) for one small high-contrast detail. **2–3 perceived colors**
  total (HIG: limit the palette).
- **FR-3 — Background.** Light/Default icon background is a **soft radial gradient**, cream
  at center → soft terracotta toward the edges (`#FAF9F5` → `#E8835A`/`#D97757`), filling
  the full 1024 canvas (no transparency). The spark + mango sit centered on top.
- **FR-4 — Master asset.** A **1024×1024** PNG, **square**, **fully opaque (no alpha
  channel)**, **sRGB**, with **corners NOT pre-rounded** (Apple applies the squircle mask).
- **FR-5 — iOS 18 variants in `Contents.json`.** The `AppIcon.appiconset` declares three
  appearances for the single universal iOS size:
  - **Light** (`appearances` omitted / "Any") — the cream→terracotta version (FR-3).
  - **Dark** — dark ground (`#1A1A18`/`#262624`) with the **terracotta/cream foreground**
    spark+mango; authored opaque (we supply a filled dark background rather than relying on
    system fill, to stay deterministic — see §6/§10 D2).
  - **Tinted** — a **grayscale** rendition with a clearly separated foreground/background so
    the system can apply the user's tint (per Apple: grayscale image, defined fg/bg).
- **FR-6 — Legibility at small sizes.** The mark must remain **recognizable at 40×40 and
  60×60 px** (downscaled from the master): the mango silhouette + burst silhouette stay
  readable; no detail that vanishes or turns muddy below ~60 px. Verified per §8.
- **FR-7 — Squircle safety / margins.** All essential shapes sit within a **safe area** so
  the squircle mask never clips the mango or burst tips: keep meaningful content within a
  centered circle of **~Ø816 px** (≈80% of 1024) and avoid placing critical detail in the
  outer **~104 px** ring; the burst's outermost points may extend into the ring but must
  not touch the canvas edge (≥ ~64 px margin).
- **FR-8 — Single vector source.** The icon is built from **one documented vector
  construction** (SVG; §6) parameterized by petal count, radii, and corner radius, from
  which the 1024 master and all variants are exported. The vector source is committed
  (e.g. `design/app-icon/mango-spark.svg`) for reproducibility.
- **FR-9 — Asset wiring.** Adding the assets must not require editing `project.pbxproj`;
  only files under `AppIcon.appiconset/` + its `Contents.json` change, and
  `ASSETCATALOG_COMPILER_APPICON_NAME` remains `AppIcon`. The app **builds and installs**
  with the new icon shown on the home screen.

### Non-functional
- **NF-Original/Legal (hard constraint).** The mark is an **original geometry** *inspired
  by* a generic friendly radial-spark motif. It **must NOT copy, trace, or closely imitate
  Anthropic's actual Claude logo/wordmark or any third-party trademark.** Differentiators
  are deliberate: an **explicit literal mango** (body + leaf) as the hero, an **even/organic
  petal burst with our own count and proportions**, and our cream→terracotta gradient — not
  a bare asterisk/sunburst alone. A reviewer must be able to articulate why it is distinct
  (see §8 acceptance + §10 D-Legal). Do not reference the Claude logo as a template during
  production.
- **NF-Brand.** Reads as warm/calm/minimal (Mango's language), not glossy, neon, or
  photorealistic. Consistent with `0002` tokens.
- **NF-Compliance.** Meets Apple's current technical rules (1024², opaque, sRGB,
  unrounded; light/dark/tinted) — see §12. No App Store rejection for icon format.
- **NF-Accessibility/contrast.** The mango silhouette maintains clear figure/ground
  contrast against the burst and ground in **all three** appearances (sanity target:
  silhouette vs immediate background ≥ ~3:1 luminance separation) so the shape is
  unambiguous; tinted variant relies on shape, not color.
- **NF-Reproducibility.** Re-exporting from the committed vector yields a
  pixel-stable 1024 master (same shapes/positions); documented export settings (sRGB, flatten,
  no alpha).
- **NF-Cost.** Zero runtime/backend cost; assets only.

## 6. Design
### 6.1 Concept (primary direction — "Mango in a warm spark")
A centered **mango silhouette** nested inside an **original radiating burst**, on a soft
cream→terracotta radial ground.

- **Ground:** full-bleed **radial gradient**, center `#FAF9F5` (cream) → outer
  `#E8835A`→`#D97757` (warm terracotta), giving a gentle glow that pushes focus to center.
  (Optionally a barely-there vignette toward `#C15F3C` at the extreme corners.)
- **Burst / spark (the "warm spark"):** an **original** set of **8 rounded petals** (lobes)
  radiating from center — *not* a thin asterisk and *not* the Claude starburst; ours are
  **soft teardrop/leaf-like lobes** with **rounded tips (corner radius ~24–32 px on the
  petal cap)**, alternating subtly in length to feel organic (4 long + 4 short, optional)
  rather than a rigid mechanical star. Petals are filled terracotta `#D97757` and may carry
  a faint inner-to-outer gradient toward `#C15F3C` for depth. The burst occupies roughly
  the **Ø560–760 px** band around center (radii below).
- **Mango (the hero, on top of the burst):** a **literal, simple mango body** — an
  asymmetric rounded ovoid (slightly plumper on one side, the classic mango "cheek"),
  ~**360 px tall × ~300 px wide**, centered, filled **cream `#FAF9F5`** (so it reads as a
  clean positive shape sitting in the warm burst) **or** terracotta-on-cream in the
  alternate (see §6.4). A small **leaf** sprouts from the top (a simple pointed-oval leaf,
  ~120 px, tilted ~25°) in a slightly deeper terracotta `#C15F3C` or charcoal-tinged green-
  neutral; one **charcoal `#1F1E1D` hairline vein/stem** (the single high-contrast detail,
  ~6–8 px stroke) gives just enough crispness to read at small size. The mango's rounded
  body doubles as the calm center the spark radiates from.
- **Read at a glance:** a friendly burst of warmth with a mango at its heart — "reading,
  energized."

### 6.2 Grid, proportions & safe margins
Canvas: **1024×1024**, origin top-left, center **(512, 512)**.
- **Keep-clear edge margin:** ≥ **64 px** on all sides (nothing touches the edge).
- **Squircle safe circle:** essential content within **Ø816** (radius 408) centered;
  primary subject (mango) ideally within **Ø640** (radius 320).
- **Optical grid:** quarter lines at 256/512/768; the mango is **optically centered**
  (its visual mass centered at ~(512, 524), nudged ~12 px low so the leaf doesn't make it
  look top-heavy).
- **Burst radii (suggested):** petal **base ring** at radius ~150 (where lobes meet the
  center disc), **long-petal tip** at radius ~360–380, **short-petal tip** at radius
  ~300–320 — long tips stay inside the Ø816 safe circle.
- **Mango bounds:** body bounding box ≈ **x∈[362, 662], y∈[330, 690]** (≈300×360),
  leaf above to ~y=300.
- **Stroke weights:** the single charcoal vein/stem ~6–8 px at 1024 scale (so it survives
  to ~1 px near 60 px). Avoid any stroke thinner than ~4 px at 1024.

### 6.3 SVG construction (producible spec)
Author one **`mango-spark.svg`** at a 1024 viewBox. Structure as **layers** (also the basis
for the iOS 26 Icon Composer version, §6.6):

```
<svg viewBox="0 0 1024 1024" width="1024" height="1024">
  <defs>
    <!-- Ground: cream center → warm terracotta edge -->
    <radialGradient id="ground" cx="50%" cy="46%" r="62%">
      <stop offset="0%"  stop-color="#FAF9F5"/>
      <stop offset="62%" stop-color="#F0C9B4"/>   <!-- cream→peach transition -->
      <stop offset="100%" stop-color="#D97757"/>
    </radialGradient>
    <!-- Petal fill: subtle depth -->
    <radialGradient id="petal" cx="50%" cy="50%" r="60%">
      <stop offset="0%"  stop-color="#E8835A"/>
      <stop offset="100%" stop-color="#C15F3C"/>
    </radialGradient>
  </defs>

  <!-- L0 BACKGROUND (full bleed, opaque) -->
  <rect x="0" y="0" width="1024" height="1024" fill="url(#ground)"/>

  <!-- L1 BURST: 8 rounded petals. Define TWO petal paths (long + short) pointing up from the
       center origin, then place 8 <use> instances at 45° increments, alternating long/short.
       Coordinates are in a center-origin frame (the parent <g> translates to 512,512). -->
  <defs>
    <!-- LONG petal: base half-width 48 at r≈150, rounded cap apex at r≈375 (tip radius 24–32);
         the Q control point past the apex (−415) creates the rounded cap (apex ≈ midpoint). -->
    <path id="petalLong"
          d="M -48,-150 Q 0,-415 48,-150 L 34,-44 Q 0,-12 -34,-44 Z"/>
    <!-- SHORT petal: same base, apex at r≈315 — gives the 4-long/4-short organic alternation. -->
    <path id="petalShort"
          d="M -46,-150 Q 0,-355 46,-150 L 33,-44 Q 0,-12 -33,-44 Z"/>
  </defs>
  <g fill="url(#petal)" transform="translate(512,512)">
    <!-- 4 long petals on the cardinal axes (0/90/180/270) … -->
    <use href="#petalLong"  transform="rotate(0)"/>
    <use href="#petalLong"  transform="rotate(90)"/>
    <use href="#petalLong"  transform="rotate(180)"/>
    <use href="#petalLong"  transform="rotate(270)"/>
    <!-- … 4 short petals on the diagonals (45/135/225/315). -->
    <use href="#petalShort" transform="rotate(45)"/>
    <use href="#petalShort" transform="rotate(135)"/>
    <use href="#petalShort" transform="rotate(225)"/>
    <use href="#petalShort" transform="rotate(315)"/>
  </g>
  <!-- For a 6-petal comp: rotate(0,60,120,180,240,300), all #petalLong. For 12: 30° steps,
       alternate long/short. Petal count is the single tunable parameter (D1). -->

  <!-- Long-petal apex at r≈375 sits comfortably inside the Ø816 safe circle (radius 408), and
       well within FR-7's ≥64px edge margin (radius ≤448). Short apex r≈315. -->

  <!-- L2 CENTER DISC (calm core the burst radiates from) -->
  <circle cx="512" cy="512" r="156" fill="#FAF9F5"/>

  <!-- L3 MANGO BODY (literal silhouette, optically centered) -->
  <!-- Asymmetric ovoid; cream fill on burst, charcoal-free except vein.
       Approx path (cubic) bounding ~x[362,662] y[330,690]: -->
  <path d="M512,330
           C600,330 662,400 662,500
           C662,610 600,690 512,690
           C430,690 372,612 372,506
           C372,404 430,330 512,330 Z"
        fill="#FAF9F5"/>

  <!-- L4 LEAF + STEM (the one charcoal accent) -->
  <path d="M512,346 C548,300 604,300 624,276
           C604,316 568,352 528,360 Z" fill="#C15F3C"/>   <!-- leaf -->
  <path d="M512,360 C516,348 520,338 520,330"
        stroke="#1F1E1D" stroke-width="7" fill="none"
        stroke-linecap="round"/>                           <!-- stem/vein -->
</svg>
```
*(Coordinates above are a buildable starting point, not pixel-final; the designer/gen step
refines curve control points so the mango reads as a friendly mango and petals feel organic.
Petal count is a parameter — default **8**; 6 or 12 are acceptable alternates per §6.5.)*

**Build options (either is fine):**
- **`canvas-design` skill / vector tool:** generate or hand-author the SVG per the above,
  then export PNG at 1024 (sRGB, flatten, no alpha). The skill can also produce the
  light/dark/tinted recolors by swapping the L0 ground + L3/L4 fills (§6.4).
- **Designer (Figma/Illustrator/Sketch):** rebuild the layers natively from these specs;
  export the same way. Commit the source (SVG or design file) under `design/app-icon/`.

### 6.4 Variant recipes (light / dark / tinted)
All three derive from the same layered source — only fills/ground change:
| Variant | Ground (L0) | Burst (L1) | Center+Mango (L2/L3) | Leaf/Stem (L4) | Alpha |
|---|---|---|---|---|---|
| **Light (Any)** | radial `#FAF9F5`→`#D97757` | terracotta `#E8835A`→`#C15F3C` | cream `#FAF9F5` mango | `#C15F3C` leaf + `#1F1E1D` stem | opaque |
| **Dark** | radial `#262624`→`#1A1A18` (or flat `#1A1A18`) | terracotta `#D97757`→`#C15F3C` (slightly brighter) | warm cream `#ECEAE3` mango | `#D97757` leaf + `#ECEAE3` stem | opaque |
| **Tinted** | flat **black `#000000`** ground | mid-grey `#8A887F` petals | light-grey `#D8D6CE` mango (clear fg/bg separation) | grey stem | grayscale, opaque |

Notes:
- **Dark:** Apple permits a transparent dark background filled by the system; we instead
  ship an **opaque dark ground** for deterministic look and to satisfy the no-alpha master
  rule cleanly (decision **D2**). Foreground stays terracotta/cream so the mango still pops.
- **Tinted:** must be **grayscale with a clearly defined foreground vs background** so the
  system tint reads; rely on **shape**, not hue. Keep the mango silhouette and burst as
  distinct grey values (e.g. mango lighter than petals than ground).

### 6.5 Alternative directions (for the design review)
1. **A — Cream mango on terracotta burst (primary, above).** Warmest, most "Mango."
2. **B — Terracotta mango, cream/negative-space burst.** Invert figure/ground: petals are
   cream "rays" carved out of a terracotta field, mango is solid terracotta with a cream
   leaf — more graphic, very strong at small size; risks reading less "warm."
3. **C — Mango *is* the spark.** The mango body sits at center and the petals emanate as a
   subtle glow/halo rather than discrete lobes (fewer, softer rays). Most minimal; leans on
   the gradient. Safest for "not-a-star" originality.
4. **Petal-count variants:** **6** (bolder, calmer), **8** (default), **12** (more
   radiant/energetic). Choose in review for best 40-px read.

Recommendation: **build A as primary**, render **B and C as comps** in the same pipeline,
pick at the design review (D1).

### 6.6 iOS 26 / Liquid Glass (recommended, optional)
For iOS 26 "Liquid Glass," Apple's free **Icon Composer** (ships with **Xcode 26**, authoring
requires **macOS Tahoe 26.4+**) consumes a **layered** source and produces the glass treatment
(translucency, specular highlights, depth) across **Default / Dark / Clear / Tinted** appearance
modes, emitting a single **`.icon`** file that adapts across iPhone/iPad/Mac/Watch. Because we
already author the icon in **discrete layers** (L0 ground, L1 burst, L2 center, L3 mango, L4
leaf/stem), we map them cleanly onto Icon Composer's **up to four depth groups**:

| Depth group | Our layer(s) | Export format |
|---|---|---|
| Background | L0 radial ground | PNG (gradient raster) or solid fill in-tool |
| Mid / burst | L1 petals (+ L2 center disc) | **SVG** (vector, scales crisply) |
| Foreground | L3 mango body | **SVG** |
| Accent (front plane) | L4 leaf + charcoal stem | **SVG** |

Apple **prefers SVG** for vector layers (PNG only for raster/blur/texture effects), which is exactly
how our source is built — so the same `mango-spark.svg` layers feed both the standard appiconset and
the `.icon`. This is **forward-looking** and **does not block shipping** the standard
`AppIcon.appiconset` (decision **D3**); track as a fast follow once we build against the iOS 26 SDK on
macOS 26.4+. The flat 1024 masters (§6.7) remain the shippable baseline for iOS 17–18.

### 6.7 Asset pipeline & wiring
1. **Author** `design/app-icon/mango-spark.svg` (layered, §6.3) + variant recolors (§6.4).
2. **Export** three opaque sRGB PNGs at 1024×1024 (flatten, strip alpha):
   - `AppIcon.png` (light/Any), `AppIcon-Dark.png`, `AppIcon-Tinted.png`.
   - Export sanity: `file AppIcon*.png` → `1024 x 1024, 8-bit/color RGB` (**color type 2**,
     no alpha). Strip any alpha if present (e.g. flatten on export, or
     `sips -s format png` / re-save without alpha).
3. **Place** the three PNGs in `ios/Mango/Resources/Assets.xcassets/AppIcon.appiconset/`.
4. **Rewrite `Contents.json`** to declare the single universal iOS size with the three
   appearances:
   ```json
   {
     "images": [
       { "filename": "AppIcon.png", "idiom": "universal", "platform": "ios",
         "size": "1024x1024" },
       { "appearances": [ { "appearance": "luminosity", "value": "dark" } ],
         "filename": "AppIcon-Dark.png", "idiom": "universal", "platform": "ios",
         "size": "1024x1024" },
       { "appearances": [ { "appearance": "luminosity", "value": "tinted" } ],
         "filename": "AppIcon-Tinted.png", "idiom": "universal", "platform": "ios",
         "size": "1024x1024" }
     ],
     "info": { "author": "xcode", "version": 1 }
   }
   ```
   (This is the Xcode-16 "Single Size" + Appearance = Any/Dark/Tinted layout; Xcode
   auto-derives all smaller sizes from each 1024 master.)
5. **No `project.pbxproj` edits.** `ASSETCATALOG_COMPILER_APPICON_NAME` stays `AppIcon`.
6. **Build & verify** on device/simulator at small sizes (§8).
7. *(Optional, iOS 26)* assemble `Mango.icon` in **Icon Composer** from the exported layers
   and add per the tool's Xcode integration.

### 6.8 Diagram (composition)
```
            1024 × 1024  (opaque, sRGB, corners NOT rounded)
   ┌───────────────────────────────────────────────┐  ← ≥64px edge margin
   │            radial ground  #FAF9F5→#D97757      │
   │        ╲      ╷      ╱    (8 rounded petals)    │
   │     ╲    ╲    ╷    ╱    ╱   terracotta burst    │
   │  ───●──── [   leaf 🌿(#C15F3C)+stem(#1F1E1D) ] │  ◌ Ø816 safe circle
   │     ╱    ╱   (mango body, cream #FAF9F5)  ╲  ╲  │
   │        ╱      ╵      ╲    optically centered    │
   │            warm glow toward edges               │
   └───────────────────────────────────────────────┘
        Apple squircle mask applied by the system ↗
```

## 7. Acceptance criteria
- [ ] The icon shows an **original radial spark/burst** with a **literal mango (body +
      leaf)** centered inside it; **no letter "m"** and **no text** anywhere. (FR-1)
- [ ] Only **brand colors** are used (cream `#FAF9F5`, terracotta `#D97757`/`#C15F3C`,
      optional `#E8835A`, charcoal `#1F1E1D`), **2–3 perceived colors**. (FR-2)
- [ ] Light/Default background is a **cream→terracotta radial gradient**, full-bleed,
      opaque. (FR-3)
- [ ] **Master** is **1024×1024**, **square**, **no alpha**, **sRGB**, corners **not**
      pre-rounded (`file AppIcon.png` reports `RGB`, color-type 2). (FR-4)
- [ ] `Contents.json` declares **light + dark + tinted** appearances for the single
      universal iOS size; all three PNGs present and opaque. (FR-5)
- [ ] The mark is **recognizable at 40 px and 60 px** (manual downscale + on-device): mango
      and burst silhouettes still read; no muddy/vanishing detail. (FR-6)
- [ ] Essential content respects the **safe area** (within Ø816; burst tips inside, ≥64 px
      edge margin) and survives the **squircle mask** with nothing important clipped. (FR-7)
- [ ] A **single committed vector source** (`design/app-icon/mango-spark.svg`) reproduces
      the 1024 master and the variants. (FR-8)
- [ ] Adding the assets required **no `project.pbxproj` edits**; the app **builds** and the
      new icon appears on the home screen, Settings, Spotlight, and App Store-style preview.
      (FR-9)
- [ ] **Originality check passes:** a reviewer can state ≥3 concrete differences from
      Anthropic's Claude logo (literal mango hero, our petal count/organic lobes, our
      gradient), and confirms it does not copy any third-party trademark. (NF-Original/Legal)
- [ ] **Dark** and **tinted** variants look intentional (mango readable; tinted relies on
      shape with clear fg/bg). (FR-5, NF-Accessibility)
- [ ] Reads as **warm/minimal/on-brand** per `0002` (not glossy/neon/photoreal). (NF-Brand)

## 8. Test plan
**Asset/format checks (scriptable, offline):**
- `file ios/Mango/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon*.png` → each is
  `1024 x 1024, 8-bit/color RGB, non-interlaced` (**no alpha / color-type 2**). Fail if any
  reports `RGBA`/color-type 6.
- `Contents.json` parses as valid JSON and contains exactly the three appearance entries
  (Any/dark/tinted) for `1024x1024` universal iOS. (lint / `python -m json.tool`)
- (If alpha sneaks in) re-export flattened; re-check.

**Build / integration:**
- `make ios-open` → build & run; confirm Xcode raises **no asset-catalog warnings** for the
  app icon and that all derived sizes generate from the single masters.
- Confirm `ASSETCATALOG_COMPILER_APPICON_NAME` still resolves (`AppIcon`) and the app
  installs with the icon visible.

**Visual QA at multiple sizes (manual — the core check):**
- Produce a **contact sheet** rendering the master at **1024, 180, 120, 87, 80, 60, 58, 40,
  29 px** (the real iOS usage sizes) and eyeball legibility/muddiness at each; the mango +
  burst must read at **40–60 px**. (HIG: verify at smallest sizes; simplify if detail
  disappears at 40 px.)
- **On device:** install on an iPhone; check **Home Screen, Spotlight search, Settings list,
  App Library, and the share/long-press** previews. Toggle **Light, Dark, and a Tinted home
  screen** (Home Screen "Customize" → Tinted) and confirm each variant looks intentional.
- **Squircle clipping:** confirm the mask doesn't clip the mango/leaf or burst tips.
- **Contrast sanity:** mango silhouette vs immediate background separates clearly in all
  three appearances (target ≥ ~3:1).

**Originality / legal review (manual gate):**
- Side-by-side the proposed mark against a generic spark motif and confirm the
  **deliberate differences** (literal mango, organic petal count/shape, our gradient); sign
  off that it does **not** copy Anthropic's Claude logo/wordmark or any third-party
  trademark. (Recorded against D-Legal.)

**No automated unit tests apply** (assets, not logic); QA is format scripts + visual review.

## 9. Rollout & migration
- **Pure asset change.** No backend, schema, flags, or runtime code. Replacing the icon is
  immediate on next build/install; users simply see the new icon after update.
- **Backward compatibility:** none broken — same asset name/key; older OS versions ignore
  the dark/tinted entries and use the light master.
- **Sequencing:** can ship independently of `0010`/`0013`; ideally land **before** an App
  Store submission (`0022-app-store-prep.md`) so the **1024 master also feeds the store
  listing icon**. If building against the **iOS 26 SDK**, follow up with the Icon Composer /
  Liquid Glass layered version (§6.6).
- **Possible follow-ups (not in scope):** user-selectable **alternate app icons**
  (`CFBundleAlternateIcons`) reusing direction B/C; seasonal variants; reusing the vector as
  the onboarding hero / in-app brand mark (coordinate with `0010`/`0013`).
- **Teardown:** none; if reverted, restore the previous `AppIcon.png` + single-image
  `Contents.json` from git.

## 10. Risks & open decisions
**Risks + mitigations**
- **Trademark/originality risk (highest).** Looking "too Claude." *Mitigation:* the **hard
  constraint** (NF-Original/Legal): lead with a **literal mango**, use our **own petal count
  & organic lobe geometry** and **cream→terracotta gradient**, never trace the Claude logo,
  and pass the §8 originality gate (≥3 articulated differences) before merge.
- **Illegible at small size.** Too many petals / thin details turn muddy at 40 px.
  *Mitigation:* 2–3 colors, ≥4 px min stroke at 1024, the contact-sheet + on-device 40–60 px
  check (FR-6/§8); simplify (fewer petals, drop the vein) if needed.
- **Squircle clipping.** Burst tips or leaf clipped by the mask. *Mitigation:* the Ø816 safe
  circle + ≥64 px margin (FR-7) and the on-device clipping check.
- **Alpha/colorspace slip.** Exporter adds an alpha channel or wrong profile → rejection or
  odd edges. *Mitigation:* flatten + strip alpha on export and the `file`/format script
  (§8); assert sRGB.
- **Dark/tinted look unintentional.** *Mitigation:* explicit variant recipes (§6.4), opaque
  dark ground (D2), grayscale tinted with clear fg/bg; on-device appearance toggle test.
- **"Mango" not legible as a mango.** A bare ovoid can read as a generic fruit/egg.
  *Mitigation:* the **leaf + stem** and the mango "cheek" asymmetry are the recognizers; tune
  curves in review; the leaf is the cheapest strong signal.

**Decisions needed (with recommendation)**
- **D1 — Direction & petal count.** A (cream mango / terracotta burst) vs B (inverted) vs C
  (mango-as-spark); 6 / **8** / 12 petals. **Recommend A @ 8 petals**, with B and C rendered
  as comps for the design review; pick by best 40-px read + originality.
- **D2 — Dark background: opaque vs system-filled transparent.** **Recommend opaque** dark
  ground (deterministic, satisfies no-alpha cleanly).
- **D3 — iOS 26 Icon Composer / Liquid Glass now or later.** **Recommend later** (fast
  follow when building on the iOS 26 SDK); ship the standard appiconset first since it covers
  iOS 17–18 and remains valid.
- **D4 — Where to commit the vector source.** **Recommend** `design/app-icon/mango-spark.svg`
  (+ variant SVGs) in-repo for reproducibility (FR-8); it is not compiled into the app.
- **D5 — Build path: `canvas-design` skill vs human designer.** Either satisfies the spec.
  **Recommend** generating first comps via `canvas-design` from §6.3, then a designer polish
  pass before final export (keeps it fast but production-quality).
- **D-Legal — Originality sign-off gate (blocking; merge-blocker).** Before the new icon merges,
  a reviewer (Principal or design owner) must complete and record an **originality checklist** in
  the PR description:
  1. **≥3 articulated differences** from Anthropic's Claude logo/wordmark, each concrete
     (e.g. "literal mango body + leaf as the hero, absent from the Claude mark"; "8 organic
     teardrop lobes at our 4-long/4-short cadence, not a thin radial asterisk"; "cream→terracotta
     **radial ground**, not a flat field").
  2. **No-tracing attestation:** confirm the Claude logo was **not** opened, traced, or used as a
     layer template during production (§5 NF-Original/Legal forbids referencing it as a template).
  3. **Third-party clearance:** the mark does not closely imitate any other shipping app icon or
     registered trademark in the category (quick visual scan of App Store "education/reading" peers).
  The checked checklist is the sign-off artifact; **without it, the icon does not ship.**
  **Recommend** running this gate against the chosen comp at the D1 design review, then re-confirming
  on the final exported master. *(Ties to AC "Originality check passes" and the §8 legal gate.)*

## 11. Tasks & estimate
1. **(S)** Lock **direction + petal count** (D1): render A/B/C comps (and 6/8/12) from §6.3
   via `canvas-design`/vector tool; design review picks one. (FR-1, §6.5)
2. **(M)** Produce the **master light vector** `design/app-icon/mango-spark.svg` to final
   geometry (mango curves, organic petals, radial ground) per §6.2–6.3. (FR-1/3/8)
3. **(S)** Derive **dark** and **tinted** recolors from the same layered source per §6.4.
   (FR-5)
4. **(S)** **Export** three opaque sRGB 1024² PNGs (flatten, strip alpha); run the
   `file`/format script to confirm no-alpha/sRGB. (FR-4, §8)
5. **(S)** Place PNGs in `AppIcon.appiconset/` and **rewrite `Contents.json`** with
   light/dark/tinted entries (§6.7). (FR-5/9)
6. **(S)** **Build & install**; confirm no asset warnings and the icon appears everywhere.
   (FR-9)
7. **(S)** **Visual QA**: contact sheet at 1024…29 px + on-device Home/Spotlight/Settings/
   App Library across Light/Dark/Tinted; squircle-clip + contrast checks. (FR-6/7, §8)
8. **(S)** **Originality/legal gate**: document ≥3 differences from the Claude logo; sign
   off non-infringing. (NF-Original/Legal, §8)
9. **(S, optional)** Commit the vector source(s) under `design/app-icon/` and a short README
   noting export settings. (FR-8)
10. **(M, optional / later)** **iOS 26 Icon Composer** layered `.icon` from the exported
    layers for Liquid Glass (D3, §6.6).

_Rough total: ~2 M + 7 S (+1 M optional iOS 26 follow-up)._

## 12. References
**Codebase**
- `ios/Mango/Resources/Assets.xcassets/AppIcon.appiconset/{AppIcon.png, Contents.json}` —
  current single-PNG icon (1024², RGB, no alpha) + single-size `Contents.json` to extend.
- `ios/Mango/DesignSystem/Theme.swift` — `Palette` (only place hex lives): `terracotta
  #D97757`, `terracottaDeep #C15F3C`, `background #FAF9F5`/`#1A1A18`, `surface #FFFFFF`/
  `#262624`, `textPrimary #1F1E1D`/`#ECEAE3`, `streak #E8835A`.
- `ios/Mango/DesignSystem/Color+Hex.swift` — `Color(hex:)` (palette source of truth).
- `ios/project.yml` — `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`,
  `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor`.
- CLAUDE.md invariants — no third-party deps; Xcode-16 file-system-synced groups (don't
  hand-edit `project.pbxproj`); no raw hex outside `DesignSystem`.

**Related specs/docs**
- `0002-claude-ui-theme.md` (palette/tokens), `0010-onboarding-redesign.md` (brand imagery /
  no-emoji), `0013-…-theme-icons.md` (in-app icon set), `0022-app-store-prep.md` (store icon
  / listing), `docs/DESIGN_SYSTEM.md`.
- **Tooling:** `canvas-design` skill (`anthropic-skills:canvas-design`) for generating the
  SVG/PNG comps and final export; Apple **Icon Composer** for the optional iOS 26 layered icon.

**External research — key takeaways (cited)**
1. **Single 1024×1024 master; Xcode derives the rest.** Apple now expects one unified
   1024 px square icon and the asset catalog generates all scaled sizes from it. —
   [Apple HIG: App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons),
   [SplitMetrics: iOS App Icon Sizes & Requirements (WWDC 2025)](https://splitmetrics.com/blog/guide-to-mobile-icons/)
2. **Master must be opaque (no alpha), sRGB, square, and NOT pre-rounded** — Apple applies
   the ~20% "squircle" mask automatically; supplying rounded corners or transparency causes
   artifacts/rejection. —
   [Apple HIG: App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons),
   [DEV: Complete iOS Icon Size Guide](https://dev.to/roboticela/the-complete-ios-icon-size-guide-for-2025-and-beyond-12ko)
3. **iOS 18 needs light + dark + tinted variants (Xcode 16 "Single Size" + Appearance = Any/Dark/
   Tinted).** Verified 2026-06: `Contents.json` declares the extra appearances via
   `"appearances":[{"appearance":"luminosity","value":"dark"|"tinted"}]` on additional `1024x1024`
   universal entries (exactly §6.7). Light = colored/light background; dark = dark background with
   color in the *foreground*; **tinted = a grayscale, fully-opaque image with a clearly defined
   foreground/background** that the system tints (omit a tinted asset → system tints the original,
   often poorly). —
   [Apple Developer Forums: add dark & tinted variants](https://developer.apple.com/forums/thread/760225),
   [createwithswift: Preparing your App Icon for dark and tinted appearance](https://www.createwithswift.com/preparing-your-app-icon-for-dark-and-tinted-appearance/),
   [HybridHeroes: iOS 18's new tinted icons](https://hybridheroes.de/blog/ios18-app-icons/),
   [Koombea: Preparing app icons for iOS 18 dark/tinted](https://www.koombea.com/blog/preparing-your-app-icon-for-ios-18-dark-and-tinted-modes/)
4. **Keep it simple, distinct, and text-free; limit to ~2–3 colors.** A single clear focal
   concept reads better than dense detail; avoid text (too small, hurts a11y/localization);
   a limited palette stays readable at 40 px. —
   [Apple HIG: App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons),
   [Median: Apple's app-icon do's and don'ts](https://median.co/blog/what-are-apples-ui-guidelines-for-app-icons)
5. **Design at 1024 but verify at the smallest sizes (down to 29–40 px); simplify if detail
   vanishes.** Recognizability at thumbnail size is the real bar. —
   [Apple HIG: App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons),
   [IconikAI: iOS App Icon Size Guidelines](https://www.iconikai.com/blog/ios-app-icon-size-guidelines-guide)
6. **iOS 26 "Liquid Glass" (optional, forward-looking):** Apple's free **Icon Composer**
   (with Xcode 26) builds layered icons (background / mid-ground / foreground, up to four
   depth groups) adapting to Default/Dark/Clear/Tinted; export each layer as SVG (preferred)
   or PNG from the same 1024 source. —
   [Apple: Icon Composer](https://developer.apple.com/icon-composer/),
   [IconikAI: Liquid Glass App Icons / Icon Composer guide](https://www.iconikai.com/blog/liquid-glass-app-icon-icon-composer-2026)
