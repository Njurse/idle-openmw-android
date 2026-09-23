# Walking out of the ship: pathfind, look, use

The first real goal of the project: **DeepSeek, inside the prison ship, walks to the trap door,
looks up at it, and uses it to step out onto the hull.**

That is a three-part problem, and each part had to be pinned to something the engine actually
does rather than something that sounds plausible.

## 1. Close enough to interact — the reach is a game setting

The engine's own Activate AI package decides it is close enough like this
(`apps/openmw/mwmechanics/aiactivate.cpp:48`):

```cpp
if (MWBase::Environment::get().getWorld()->getMaxActivationDistance() >= targetDir.length())
```

and that distance is read from a **GMST** (`iMaxActivateDist`,
`apps/openmw/mwworld/worldimp.cpp:890`). A GMST is moddable, so it is read at runtime
(`core.getGMST('iMaxActivateDist')`, `scripts/runtime/interact.lua:reach`) and the documented
default of 128 is only a fallback. Hard-coding 128 would work on vanilla and quietly fail on
anyone's modded game.

The player keeps walking until within that reach, and stops *just inside* it
(`aim.ARRIVE_MARGIN`), because stopping exactly on the boundary makes the arrival test flicker.

## 2. Looking — and why the yaw convention is not a guess

The engine faces a target with **`atan2(dx, dy)`** — x first
(`apps/openmw/mwmechanics/aiactivate.cpp:44`, identically `aiface.cpp:17`). That is *not* the
usual maths convention, and getting it wrong makes the actor walk sideways while staring at the
target, so it is pinned by a spec (`tests/spec/aim_spec.lua`).

Pitch is written to the camera's **extra** angles, not its base ones. The camera's real
orientation is `getPitch() + getExtraPitch()` (`openmw/camera.lua`), and the base pose is what
the game itself drives — including our own isometric lock (`scripts/idle/camera.lua`), which
writes the base pose every tick. Aiming at the base angles would make the two fight each other
and the camera twitch. Aiming at the *difference* composes with whatever the base pose is.
An engine without the extra angles falls back to the absolute pose, and says which it used
(`aimAt(...).method`).

Because the pitch sign is inferred from the camera's quaternion order
(`apps/openmw/mwrender/camera.cpp:198` — `Quat(pitch, X) * Quat(yaw, Z)`) rather than from a
line of documented intent, the aim is **verified**, and the verification does not trust our own
arithmetic:

```
aim  -> write the angle
ask  -> camera.viewportToWorldVector(0.5, 0.5)   -- where does the ENGINE think we look?
cast -> nearby.castRay(eye, eye + thatDirection * reach)
check-> is the thing at the end of that ray the thing we aimed at?
```

If the first attempt is not looking at the target, the other pitch convention is tried **once**
(`interact.aimAndVerify`). One correction, then it reports failure: a loop that flip-flops
between two conventions is worse than an honest "I could not get it in the crosshair".

## 3. Using it — `activateBy`

`object:activateBy(actor)` (`openmw/core.lua:205`) is the Lua route to the engine's own
activation. Internally that is `LuaManager::objectActivated`, the same call the Activate AI
package makes (`apps/openmw/mwmechanics/aiactivate.cpp:57`). For a **teleport** door — and only
teleport doors move you between cells (`types.Door.isTeleport`) — activation is what travels, so
that single call is the whole of "open the hatch and step out".

Note what is *not* available: Lua cannot press the activate key. `openmw.input` exposes no
action-value setter (the full surface is `inputbindings.cpp`, and there is no `setActionValue`),
and the engine's own triggers are a fixed set (Jump, ToggleSneak, …) with no Activate among them
(`resources/vfs/scripts/omw/input/playercontrols.lua:118`). So the mod calls the object
directly rather than pretending to press a key.

## The loop

`startExit()` / `updateExit()` in `mods/idle_openmw/scripts/idleDirector.lua`, one step per
frame:

| Step | When | What happens |
|---|---|---|
| `seek` | always | read the nearby doors, choose one (`aim.chooseExit`) |
| `move` | out of reach | submit `{type='move', dest=<door>}` — the executor pathfinds and steers |
| `aim` | in reach, not aimed | `interact.aimAndVerify` — the "look up at the hatch" step |
| `activate` | in reach and aimed | `interact.activate` |
| `verify` | after using | compare the player's **cell** before and after; changing is success |

Choosing the door is deliberately not "the nearest door": a cupboard is nearer than an exit, so
a door under the crosshair wins (the player is already looking at it, and a tap should be
respected), then the nearest **teleport** door, and only then any door.

**Verification is the point.** `idle-openmw: exit -> OUT: Imperial Prison Ship -> Seyda Neen`
is evidence; "I called activate and it did not throw" is not. Failure is bounded (45 s of
frames, 4 uses) and honest: `exit -> FAILED: used it 4 times and did not move`.

Driven from:

* the console's **"Go out"** action (`ACTIONS.go_out`);
* the bridge: `{"method":"world.exit"}`, with `{"method":"world.exitState"}` to poll it
  instead of reading the log.

## Live status, honestly

The loop has been exercised on the engine and the parts that do not need an unpaused world are
confirmed. What is *not* yet demonstrated end to end is the last step, because it needs a
specific game state:

* **`--skip-menu=1` on its own does not put you in the ship.** It bypasses character creation
  (`engine.cpp:1029` → `newGame(bypass=true)`, `statemanagerimp.cpp:164`), which places the
  player in the **exterior** — the log shows `Loading cell West Gash Region` — so there is no
  cabin to walk out of. Good for testing world behaviour, useless for testing this.
* **A real new game does put you in the ship** (`Loading cell Imperial Prison Ship`), but it
  stops at character creation, where the world is paused (`dt = 0`) and the mod cannot move or
  aim. Reaching the cabin therefore depends on getting through chargen, which is where the
  mod's own UI reporting earns its keep: the live log shows

  ```
  idle-openmw: screen -> ChargenName
  idle-openmw: BLOCKED (menu) paused by an open window: ChargenName. The mod can close it...
  idle-openmw: screen -> empty
  idle-openmw: BLOCKED (messageBox) paused with no window open: a message box is up...
  ```

  i.e. it names the window, then names the *next* blocker once that window closes — the two
  causes of a stopped world (docs/ui-inventory.md), told apart on the engine and not just in a
  spec.

So the remaining work on this goal is chargen, and the tooling now says exactly which window is
in the way at each moment.
