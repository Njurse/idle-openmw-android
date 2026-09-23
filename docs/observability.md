# Observability: watching the bot think

An idle bot fails slowly and quietly. The player-facing log
(`scripts/idle/activityLog.lua`) is short and friendly; that is exactly the wrong
tool for finding out *why* a 1000-hour run drifted. This is the tool for that.

## The decision trace

`scripts/idle/trace.lua` is a bounded, **pure** recorder. The director appends one
event per **goal transition** (with the reason and the command count), one per
**order**, and one when the **phase** changes. Nothing per-tick, so the timeline
stays readable.

```
python tools/run_tests.py --sim --trace
```

```
  goals: explore=8114 fight=22754 ...
  trace (goal=48741  order=0  phase=1):
  3598170.0  goal      survive (health 44% (critical at 25%))  [cmds=2]
  3598200.0  goal      quest (quest objective nearby)  [cmds=1]
  3598260.0  goal      fight (1 hostiles, danger 0.20)  [cmds=1]
  3598290.0  goal      quest (quest objective nearby)  [cmds=1]
  ...
```

`HARNESS_TRACE_LINES` caps the printout (`HARNESS_TRACE_LINES=200`).

The same recorder is available in-game: `director:traceLines(n)` /
`director:traceSummary()`, and the panel carries the summary.

## What the trace already found

Its first job was to look at a long run, and it immediately showed something the
green invariants had hidden: late in the run the director **thrashes between
`quest` and `fight`** roughly every step (~40% of all steps are a goal change --
`warrior goal changes: 48741` of 120000). The sim is green because nothing
*breaks*; the bot is just dithering.

### The fix was tried, measured, and rejected

A goal **hysteresis** -- keep the current goal unless another beats it by a margin
-- is the obvious experiment, so it was built (`director.applyHysteresis`, the
`behaviour.hysteresis` knob, unit-tested) and then **measured against the sim**
(same seed, so the numbers are comparable):

| `behaviour.hysteresis` | goal changes | gold at 1000h | invariants |
| --- | --- | --- | --- |
| `0.0` (default) | 48741 | 2721 | hold |
| `0.25` | 45855 (-6%) | 1994 (**-27%**) | hold |
| `0.6` | 43539 (-11%) | 2142 (**-21%**) | hold |

It buys a tenth off the thrash and pays a fifth of the income: staying put
*entrenches cheap goals* instead of cycling on to the profitable ones. So it ships
**off**, with the knob kept and the measurement written down. This is the point of
the exercise -- the trace made a hypothesis cheap to test and cheap to *reject*,
rather than shipping a plausible-sounding "fix" that quietly makes the bot poorer.

The remaining thrash is therefore not obviously a defect: the cycling appears to be
doing useful work. A better lever, if one is wanted, is to make `fight`'s *need*
less eager rather than to freeze the goal -- measure it the same way.

## Related test tools

| Tool | What it shows |
| --- | --- |
| `tests/spec/firstRun_spec.lua` | the whole new-game -> chargen -> Seyda Neen flow, tick by tick |
| `tests/sim/headless_sim.lua` | 1000 game-hours of invariants (streaks, gold, errors) |
| `python tools/preview_console.py --png` | what the console looks like, without the game (`docs/theme.md`) |
| `--only <substring>` | isolate one spec while iterating |

## Reading the bridge's answers out of `openmw.log`

The bridge writes one `IDLEAPI {json}` line per answer. Two things bite when you script
against that log, both measured on the forked 0.52 build:

- **A large payload can be interleaved.** `player` on a live save is a few kilobytes, and the
  engine's log emitted it with another thread's line spliced *inside the JSON*
  (`..."swimming"[07:29:10.416 *] false,...`), which no JSON parser will accept. Small answers
  (`ui`, `world.pauseTags`, `ui.hints`) are reliable; for a big one, prefer a narrower method,
  or ask twice and take the answer that parses.
- **Locate the answer by `id`, not by "the last line".** Frames are logged continuously, so the
  answer is whichever line carries your request id.

The `ui` report is deliberately small and is the channel to prefer: it carries the director's
decision, the live and snapshot positions, the camera state and the `nearbyLists` shapes.

## Dev verbs (operator channel)

Write one line into `mods/idle_openmw/dev_command.txt`; it is polled and consumed.

| Verb | Effect |
| --- | --- |
| `dump` (or `ui`) | print the UI report |
| `heartbeat <seconds>` | periodic frame summary |
| `telemetry <seconds>` | periodic counters |
| `note <text>` | record an operator note |
| `camera on\|off` / `camera pitch <r>` / `camera distance <u>` | the isometric lock |
| `economy gold <n>` / `economy give <id> [n]` / `economy take <id> [n]` | probe the player -> warden economy channel |
| `stop` | stop the periodic output |

`economy` exists because the economy is not otherwise reachable without a merchant in front of
you, and because the player script *cannot* do it itself (`docs/openmw-lua-api.md` §10.1, and
`docs/world-model.md`). Its live proof on the built engine:

```
[idle-openmw/warden] economy gold: 250 gold          # world.createObject + moveInto
[idle-openmw/warden] economy take: 250 x gold_001    # it was really there, so it could be taken
[idle-openmw/warden] economy take: FAILED - not carried: exp_sword_01   # the control
```
