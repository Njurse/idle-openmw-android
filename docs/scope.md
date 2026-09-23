# Project scope

The single page that says what `idle-openmw` is *for*, why it exists, and what is left.
Everything else in `docs/` is a detail of one line below.

## The scope, in the user's words

> autonomous Morrowind play in **portrait mode** on my phone from an **isometric
> perspective**, with a nice mobile-formatted GUI for options, journal, inventory, wait,
> go to town, explore, map (with go-somewhere), and dialogue handling. Think of it as
> Morrowind shrunk to fit — the game up near the top, a Morrowind-themed UI filling the
> rest of the screen below. And the ability to **tap an NPC or an object** and get
> dialogue to open / unlock / steal / take / talk / attack. The AI will need combat
> abilities eventually, but first establish the **pathfinding AI**, then set it up to
> allow modular, state-/stat-based behaviours for the future.
>
> **The super goal:** the whole thing on **Android** — go through **character creation**,
> **buy something from the shop with the high elf** (Arrille, in Seyda Neen), then
> **exit the shop**.

That is the contract. It is deliberately ambitious; the tracks below are how it gets
built, and the status of each is kept honest against the engine's real capabilities.

## The tracks

| # | Track | Deliverable | Status |
|---|---|---|---|
| 1 | **Pathfinding** | Walk anywhere: along the navmesh, to interaction range, through doors, across cells | 🟡 single-cell steering + route cache done; cross-cell and door traversal in progress |
| 2 | **Isometric view** | A locked pitched/distance camera, roofs hidden | 🟡 the angle is a Lua `openmw.camera` lock (`idle/camera.lua`, off by default); roofs need engine work (`docs/isometric.md`) |
| 3 | **Portrait + console** | The game on top, a Morrowind-themed tabbed console below | ✅ six-tab console, tested geometry + interaction model (`docs/console.md`, `docs/theme.md`) |
| 4 | **Dialogue handling** | Topics, responses, the journal | 🟡 observed and remembered (`idle/dialogue.lua`); the engine cannot *select* a topic (`docs/dialogue.md`) |
| 5 | **Tap an entity** | Tap → walk / enter / talk / take / unlock / attack | ✅ raycast picking + walk-to (`docs/tap-to-move.md`); action verbs are growing |
| 6 | **Modular behaviours** | State-/stat-driven goals, swappable | ✅ pure goal-scoring over class + stats (`idle/goalScoring.lua`, `idle/statCrunch.lua`) |
| 7 | **Combat** | Fight what the enemy model says is hostile | 🟡 threat assessment + opt-in NPC hostility (`idle/combat.lua`); no player AI packages exist (`docs/limitations.md` §1.1) |
| 8 | **Android build** | A modern engine for the phone | ⛔ the published APK predates `.omwscripts` and cannot load the mod (`docs/android.md`); now building from source (`docs/engine-build.md`) |

## Definition of done (the super goal)

On Android, unattended:

1. The game loads and opens into character creation.
2. Character creation completes (name + race/class/birthsign + review).
3. The character is in the world, and the console is live.
4. The director walks the character into Arrille's Tradehouse in Seyda Neen.
5. It buys something from Arrille.
6. It leaves the shop.

Steps 1–3 are the **engine/chargen** problem; 4–6 are the **pathfinding + interaction +
economy** problem. Both are being driven at once because the second cannot be trusted
until the first can be observed.

**Status of step 2 (measured on the forked 0.52 engine, `docs/chargen.md`):** chargen
*cannot* be finished from Lua. `chargenstate` is set to `-1` by Morrowind's own `CharGen`
script, which only runs while the world is unpaused — the opposite of the state chargen
holds. So the world is reached the documented way (`tools/dev/desktop/into-world.sh`,
the engine's `bypass` path) and Android chargen waits on an engine change.

## The engine floor

The mod needs a **modern OpenMW**. The measured floor is **0.49+** (Lua API revision
129 on 0.51); the reasons are in `docs/openmw-lua-api.md`. Desktop iteration runs on a
build we produce ourselves (`docs/engine-build.md`); Android needs that same build
cross-compiled, which is why track 8 is a build problem before it is a UI problem.

## How this scope is pursued

- **Proof over assertion.** A capability is "done" only with a `file:line` citation in
  `docs/openmw-lua-api.md` or a spec in `tests/`. Two "limitations" in this project's own
  history turned out to be false and had to be corrected (`docs/plan-reconciliation.md`,
  C7) — so every claim is re-checked, including the ones already written down.
- **The safe default is the shipped default.** Where the engine cannot tell us something
  (is this NPC hostile?), the feature is opt-in and the limitation is written down.
- **The brain stays pure.** `scripts/idle/*` is plain tables in, plain tables out, so all
  of the above is testable without the game (`AGENTS.md`).
