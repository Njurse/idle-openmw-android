# The isometric perspective

An idle game reads best from a fixed, overhead angle: you watch the character
work, not through their eyes. This is how far that can be taken in this mod, and
where the wall is.

## It is a runtime feature, not an engine patch

The original plan filed the isometric camera under "needs OpenMW C++ work"
(`docs/plan-reconciliation.md`, phase 2, on the strength of the *OpenNevermind*
mod). That was wrong. `openmw.camera` is one of the packages handed to a **PLAYER
script** (`apps/openmw/mwlua/luabindings.cpp:73`), and it exposes exactly what a
fixed camera needs (`apps/openmw/mwlua/camerabindings.cpp`):

```lua
local camera = require('openmw.camera')
camera.setMode(camera.MODE.ThirdPerson)
camera.setPitch(-0.6109)                  -- ~ -35 degrees, forced
camera.setPreferredThirdPersonDistance(640)
```

The key detail is that `setPitch`/`setYaw` are **forced**: the engine's
`Camera::setPitch(angle, force)` sets `mLockPitch` when forced
(`apps/openmw/mwrender/camera.cpp:320`), so one call *latches* the angle and the
game's own look controls stop moving it. That is the "lock".

## Where the numbers live

- `scripts/idle/camera.lua` — **pure**: decides *whether* to lock and with what
  pitch/distance, clamped to a sane range. Unit-tested (`tests/spec/camera_spec.lua`).
- `scripts/idleDirector.lua` — the applying half: calls `openmw.camera` when the
  plan says to. A no-op outside the world, so it never fights character creation.

Config (`scripts/idle/config.lua`, `camera`):

| Key | Default | Meaning |
| --- | --- | --- |
| `isometric` | `false` | master switch — **off by default** |
| `pitch` | `-0.6109` | radians; ~ -35°, the classic 2:1 iso tilt |
| `distance` | `640` | third-person distance, engine units |

## It is verified on the built engine

The lock was a claim until it was measured on the forked 0.52 engine. It is now:

```
dev_command.txt: "camera on"        # turns the lock on at runtime
-> idle-openmw: camera isometric=true pitch=-0.6109 distance=640
bridge "ui" before: camera = { mode = 3, pitch = 0,       yaw = 0.84, distance = 192 }
bridge "ui" after : camera = { mode = 3, pitch = -0.6109, yaw = 1.18, distance = 192 }
```

`pitch` lands on the configured value exactly, which is the lock: `camera.setPitch(v)`
binds to `Camera::setPitch(-v, true)` — the `true` is `force`, so it latches `mLockPitch`
and the game's own look controls stop moving it (`camerabindings.cpp:55`,
`mwrender/camera.cpp:320`). The dev channel verbs are `camera on|off`,
`camera pitch <radians>`, `camera distance <units>`; the applied state is readable from
the bridge's `ui.camera`, because an isometric lock is otherwise invisible from outside.
| `yaw` | `nil` | a fully-fixed heading in radians; `nil` = follow the actor |
| `inManual` | `false` | keep the lock even while the human is driving |

It is **off by default on purpose**: a forced camera angle is not something to
spring on a first run, and the exact angle is a taste that wants a real screen to
judge. Turn it on from the console's **Setup** tab (`Isometric camera`) to try it.

Not yet judged on a screen: the pitch *sign* and the distance are arithmetic and
tested, but the pixels are not — same caveat as the layout overrides in
`docs/ui-overhaul.md`.

## The honest limit: it cannot hide the roofs

An overhead view of Morrowind looks **through building interiors and under
doorframes**: the camera sees the ceiling/roof of the cell the character is in,
and the walls of the ones around it. The note it answers ("backface cull the
landscape/buildings?") does not fix this, and it is worth saying why:

- OpenMW **already culls back faces** — the shadow pass is the only place that
  deliberately flips to front-face culling (`components/sceneutil/mwshadowtechnique.cpp:1681`);
  the visible pass culls back faces as normal.
- The occluders in an overhead view are **front** faces: a roof's outer surface,
  a wall's near side. Culling them would punch holes in the world, not reveal it.

What actually solves it is an engine feature — a "cutaway" mode that hides
scene-graph nodes above a height threshold, or per-cell "no roof" flags — which
is C++ rendering work in the port, not data and not Lua. That belongs in the
port's patch layer (`buildscripts/patches/openmw/`) alongside the orientation and
inset changes named in `docs/android.md` §"The good news".

So today: the isometric *angle* is a Lua toggle, and the roof problem is a known,
named piece of engine work, not a mystery.
