# The engine ↔ host bridge

An API for asking the **running game** about itself, so a host layer (the Android app, a
desktop tool, a monitor) can see what the engine sees. Grounded in the constraints in
[docs/ui-inventory.md](ui-inventory.md): OpenMW's Lua can neither open a socket nor write a
file, but it **can** read a file from the data folder (`openmw.vfs`) and `print`.

So the channel is one line in, one line out.

```
in   mods/idle_openmw/idle_api.txt        {"id":4,"method":"entities.nearby"}
out  engine log / stdout                  IDLEAPI {"id":4,"ok":true,"result":{...}}
```

The same `print` stream goes to stdout, so a parent process that **launched** the engine can
read it directly; otherwise tail `openmw.log` and filter on `IDLEAPI `.

## Requests

One JSON object per line. Blank lines and `#` comments are ignored, so a request file can be
annotated. Re-read once a second; identical content is not answered twice, so **change the
file to ask again** (or add a new `id`).

```jsonc
{"id": 1, "method": "cell.current"}
{"id": 2, "method": "player"}
{"id": 3, "method": "ui.hints"}
{"id": 4, "method": "entities.nearby", "params": {"radius": 512}}
{"id": 5, "method": "action", "params": {"goal": "go_town", "ttl": 120}}
```

`id` is echoed back so answers can be matched to requests. `method` is required.

## Responses

```jsonc
{"id": 4, "ok": true,  "result": {...}}
{"id": 5, "ok": false, "error": "unknown method: nope", "hint": "ask for \"schema\""}
```

An error is always an answer. A bridge that dies on a bad line is not one a host can trust.

## Methods

| Method | Answers |
|---|---|
| `ping` | identity, protocol version, whether the clock is real time |
| `schema` | **every method and its parameters** — ask this instead of hard-coding us |
| `capabilities` | what this engine supports (0.49+ floor; 0.51 = Lua API r129) |
| `player` | name, position, cell, level, gold, health, fatigue, magicka |
| `cell.current` | name, region, exterior flag, grid x/y |
| `entities.nearby` | actors/doors/activators/containers with distance (`params.radius`) |
| `entity.get` | a **remembered** entity by `params.id` — see *Naming an entity later* below |
| `registry` | what the mod currently remembers: `cap`, `count`, `evicted`, `entities` |
| `quests.active` | started, unfinished quests with their current stage |
| `journal.topics` | journal topics the player has heard of |
| `ui` | the UI report: open window, pause, phase, geometry (see ui-inventory.md) |
| `ui.target` | **what the crosshair is on**, with distance and above/below |
| `ui.interactables` | doors/containers/actors/activators, nearest first |
| `ui.hints` | the derived on-screen advice, in the imperative |
| `action` | ask the mod to do something (`params.goal`, optional `params.ttl`) |

`action` routes through the director's own directive channel, so a request from a host is the
same thing as a tap in the console: one path, one set of rules, one set of play modes.

## Naming an entity later

Three requests in a row are the reason this exists:

```
{"id": 1, "method": "ui.target"}                        -> the hatch, id "1445"
{"id": 2, "method": "entity.get", "params": {"id": "1445"}}
{"id": 3, "method": "action", "params": {"goal": "walk_to"}}   (later: entity.activate)
```

A host speaks text; the engine speaks userdata. So the id in a response refers to something the
host cannot hold, and there is no way to ask for it again from the response alone. Between
requests the mod therefore **remembers** the entities it reads
(`scripts/idle/registry.lua`), keyed by the engine's own unique string (`GameObject.id`), and
`entity.get` looks one up by that key.

Three rules, because each one is a trap:

1. **Identity, not state.** What comes back is what we remembered: `id`, `kind`, `formId`,
   `recordId`, `name`, which nearby list it came from, the `position` and `cell` we last saw it
   in, and `lastSeen`/`seen`. It is **not** a fresh read, so do not treat the remembered
   `position` as current and do not expect health or inventory. That is also why `entity.get`
   is declared `returns = "free"` rather than `"entity"`: a remembered record is honestly a
   subset, and calling it an entity would be a quiet lie.
2. **A miss is `ok: true` with `result: null`**, not an error. An id can be unknown because it
   was never read, because it aged out (see 3), or because the host made it up; none of those
   are a broken call. Every miss also writes a line to the decision trace, so a stale reference
   is visible in the log instead of mysterious.
3. **Bounded, least-recently-seen evicted first.** `params.ui.registryCap` (default 200)
   entities are kept. `registry` reports `cap`, `count`, `evicted` and `entities` (most recent
   first), so a host can both notice eviction and recover: anything evicted is still reachable
   by re-reading `entities.nearby` or `ui.interactables`.

That last point is the design rule worth keeping: the registry is a **convenience for hosts,
never the only way to reach something.** If a host could only act on what it had already been
told about, forgetting an id would be unrecoverable.

## Watching instead of asking

```
heartbeat 10      # human-readable UI report every 10s
telemetry 10      # machine-readable telemetry every 10s
```

both written into `mods/idle_openmw/dev_command.txt` (gitignored, like `idle_api.txt` and
`narration.txt`).

```
IDLEAPI {"ok":true,"telemetry":true,"result":{"player":{...},"cell":{...},"ui":{...}}}
```

## The HUD problem, and why `ui.hints` exists

Morrowind tells the player *"look up at the hatch and press space to open it"* in a native
widget, and **Lua cannot read the engine's widgets** (`ui.getElements` returns only elements
the Lua layer created — and in 0.51 it does not exist at all). So the bridge derives the same
information instead:

* what the crosshair is on → `camera.viewportToWorldVector(0.5,0.5)` + `nearby.castRay`
* what is reachable → `nearby.doors` / `containers` / `activators` / `actors`
* what key → `input.ACTION.Activate`, with the key name as a documented default (`Space`)

A hint therefore names the direction and the key: *"Look above: there is a door (hatch) —
press Space to open it."*

## Two limitations worth knowing before you build on this

1. **`dt` is 0 while the world is paused.** Measured on the engine: `dt=0` on every frame a
   paused world renders, `1/60` once it runs. Anything accumulating `dt` stalls — which once
   made a paused game look like a frozen mod. Observation channels therefore advance on a
   **nominal** frame time, while the director's simulation keeps the real `dt` and refuses to
   act during a pause. Ask while paused and you get answers; do not expect the world to move.
2. **The engine fills its `nearby` lists only while the world runs**, so `ui.interactables`
   and `entities.nearby` are empty during a pause. `player` and `cell.current` do not depend
   on that: they read the engine directly, precisely so a host can ask *why* nothing is
   happening.

## Adding a method

1. Add it to `M.METHODS` in `scripts/idle/bridge.lua` (this table **is** the documentation —
   `schema` serves it).
2. Map it in `SOURCE_METHODS` and provide the source in `bridgeSources()`
   (`scripts/idleDirector.lua`).
3. Anything whose logic is not engine access belongs in a pure module with a spec — see
   `scripts/idle/hud.lua` and `tests/spec/hud_spec.lua`.
