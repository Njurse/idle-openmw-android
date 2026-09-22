# Tap to move, enter a door, talk to an NPC

A tap on the world is playability: point at a spot and the character walks there;
point at a door and it opens; point at an NPC and the dialogue window comes up.

## How a tap becomes a world position

```
  touch  ─▶ mouseRelease event.position (absolute pixels)   [lua_ui/widget.cpp:566]
         ─▶ normalize: pos / ui.screenSize()                (0..1, top-left origin)
         ─▶ camera.viewportToWorldVector(n)  -> direction    [camera.lua:236]
         ─▶ nearby.castRay(cameraPos, cameraPos + dir*reach) [nearby.lua:79]
             -> { hit, hitPos, hitObject }
         ─▶ tapMove.intent(pick, player) -> walk / enter / talk / use / none
         ─▶ pushDirective('walk_to', intent) -> move + (activate)
```

Two details that decided the design:

- **`mouseClick` carries no position.** The Lua UI click event passes nothing
  (`components/lua_ui/widget.cpp:546`); `mousePress`/`mouseRelease` do
  (`:559`/`:566`, `event.position`). So tap-to-move listens on **`mouseRelease`**.
- **`camera.viewportToWorldVector` is exposed to PLAYER scripts** — it is part of
  `openmw.camera`, which is a player package (`docs/openmw-lua-api.md` §12).

## Who does what

| Piece | Layer | Job |
| --- | --- | --- |
| `portraitUI` | renderer | a **full-screen Widget** under the console, on `mouseRelease`, forwards `{ x, y }` to `act('walk_to', …)`. It does **no** engine maths. |
| `idleDirector` | runtime | normalizes the point, raycasts (`pickAt`), classifies the hit object (door / actor / container / activator / world), and pushes the `walk_to` directive. |
| `idle/tapMove.lua` | pure | turns a pick into an **intent**, and computes where to *stand* (a standoff short of the target). Unit-tested. |
| `idle/director.lua` | pure | `walk_to` → `{ type = 'move', dest }` + `{ type = 'activate', kind, target }`. |

The full-screen layer is created **first**, so the console's own widgets sit on
top and keep their taps. It sets `ignorePointerEvents = true` in **MANUAL** mode
(or when `ui.tapToMove` is off), so the game's own touch controls still receive
input when the human is driving.

## Options

- `ui.tapToMove` (default **true**) — Setup tab: "Tap the world to move".
- `ui.tapReach` (default 4096 units) — how far a tap can reach before it is
  refused as "too far away".

## What a tap means

| You tapped | Intent | Result |
| --- | --- | --- |
| a door | `enter` | walk up, then activate it (you go through) |
| an NPC / creature | `talk` | walk up, then activate it (dialogue opens) |
| a container / activator | `use` | walk up, then activate it |
| ground or scenery | `walk` | walk to the exact spot |
| nothing / too far | `none` | nothing, and the Log tab says why |

`dest` is the tapped point pulled **96 units toward you** (except bare ground, and
never past your own position), so you stop *beside* the door rather than inside
it.

## Honest limits

- The layer is a **UI element over the game viewport**. Whether a touch reaches it
  on Android depends on the port's touch handling; it is tested headlessly
  (`tests/spec/tapMove_spec.lua`, the `walk_to` runtime specs), not on a device.
- A tap targets the **first thing the ray hits**. There is no "tap through the
  window to the street behind it".
- It does not pick dialogue topics — that is still the game's window
  (`docs/dialogue.md`).
