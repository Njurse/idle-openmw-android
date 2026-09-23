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
2. **A miss is `ok: true` with no `result` key at all** (not an error, and not `result: null`
   either — a nil result is omitted from the envelope, so a host must read "no result" as
   "nothing to report", never as a failed call). An id can be unknown because it was never
   read, because it aged out (see 3), or because the host made it up; none of those are a
   broken call. Every miss also writes a line to the decision trace, so a stale reference is
   visible in the log instead of mysterious.
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
   (`scripts/idleDirector.lua`). `tests/spec/bridge_spec.lua` then asserts that every method in
   `M.METHODS` is actually wired to a source, so a declared-but-dead method cannot ship.
3. Anything whose logic is not engine access belongs in a pure module with a spec — see
   `scripts/idle/hud.lua` and `tests/spec/hud_spec.lua`.

## A live transcript, and why the pause matters

Recorded on OpenMW 0.51.0 (Lua API r129) sitting at **ChargenName**, with the world paused and
`dt = 0` on every frame. Requests were left in `mods/idle_openmw/idle_api.txt`; answers came
back under the `IDLEAPI ` prefix:

```
IDLEAPI {"id":901,"ok":true,"result":{"api":1,"methods":19,"mod":"idle-openmw"}}
IDLEAPI {"id":902,"ok":true,"result":{"cap":200,"count":0,"entities":{},"evicted":0}}
IDLEAPI {"id":903,"ok":true,"result":{}}
IDLEAPI {"id":904,"ok":true}
```

alongside, from the same run:

```
idle-openmw: screen -> ChargenName
idle-openmw: BLOCKED (menu) paused by an open window: ChargenName. The mod can close it...
idle-openmw: frame 300 dt=0 sinceSnapshot=1.0241555776447
```

Three things this pins down, each of which was a bug before it:

- **A paused world is still answerable.** The poll used to be gated on accumulated `dt`, which
  is `0` for every frame of a paused world — so the channel went silent exactly when a host most
  wants to ask "what is going on?". It is frame-counted now (`everyFrames`), which is why these
  four lines exist at all.
- **`screen -> ChargenName`, not `screen -> empty`.** The mode stack is engine *userdata*; a
  `type(stack) == 'table'` test called a real open window "empty".
- **`BLOCKED (menu)`.** Pausing is reported with its *cause*, and the cause names the remedy: a
  mode the mod can close, versus a message box only the host can clear.

`count: 0` in 902 is honest and not a fault: at chargen nothing has been read yet, so nothing is
remembered. Ask `entities.nearby` first and the registry fills.

## `ui.target` when there is nothing to look at

`ui.target` is validated as an **entity**, so "the crosshair is on nothing" must be `null` — an
explanation table there is a schema violation (`entity has no kind`), which is exactly what the
validator said to the first version of this change. The reason travels through `ui.hints`
instead, which is free-form text:

```
{"id": 1, "method": "ui.target"}   -> {"id": 1, "ok": true}          (no result: nothing there)
{"id": 2, "method": "ui.hints"}    -> ["Nothing in front of you. Nearest: player (0 away).
                                       (the ray hit nothing)"]
```

The parenthetical matters. A bare "nothing in front of you" reads identically whether the ray
genuinely hit nothing or the pick is broken — and the pick *was* broken for a long time, because
`camera.viewportToWorldVector` returns a Vector3 **userdata** and `nearby.castRay` returns the
registered `RayCastingResult` **userdata**, both of which were guarded as `type(x) == 'table'`.

## Engine values must not reach the wire

The schema's `map`/`list` checks now reject an **engine value nested anywhere inside** a field.
They used to be `type(v) == 'table'` and nothing more, so `types.Actor.stats.ai` — an AI
disposition *wrapper*, not a number — validated, then serialised as the literal string
`"<userdata>"`. A host asking for the AI dispositions, which are how the mod judges hostility,
received confident nonsense and nothing complained. Now:

```
"ai": {"alarm": 0, "fight": 83, "flee": 30, "hello": 0}
```

Positions are the one documented exception: they may *be* userdata, because that is how the
engine hands them over.
