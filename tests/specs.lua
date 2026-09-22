-- tests/specs.lua
-- Fallback manifest for running the suite without the Python runner
-- (e.g. `luajit tests/run.lua`). `tools/run_tests.py` globs tests/spec/*_spec.lua
-- and passes that list as the authoritative `HARNESS_SPECS`; it also warns if
-- this manifest has drifted from what is on disk.
return {
  'tests.spec.activityLog_spec',
  'tests.spec.classPriorities_spec',
  'tests.spec.combat_spec',
  'tests.spec.config_spec',
  'tests.spec.dialogue_spec',
  'tests.spec.directive_spec',
  'tests.spec.director_spec',
  'tests.spec.economy_spec',
  'tests.spec.equipment_spec',
  'tests.spec.goalScoring_spec',
  'tests.spec.guardian_spec',
  'tests.spec.harness_spec',
  'tests.spec.idleDirector_spec',
  'tests.spec.offlineProgress_spec',
  'tests.spec.pathfinder_spec',
  'tests.spec.portraitUI_spec',
  'tests.spec.rng_spec',
  'tests.spec.runtime_spec',
  'tests.spec.statCrunch_spec',
  'tests.spec.uiLayout_spec',
  'tests.spec.uiState_spec',
  'tests.spec.worldsense_spec',
  'tests.spec.uiModel_spec',
  'tests.spec.settlement_spec',
  'tests.spec.notify_spec',
  'tests.spec.util_spec',
  'tests.spec.lifecycle_spec',
  'tests.spec.camera_spec',
  'tests.spec.theme_spec',
  'tests.spec.firstRun_spec',
  'tests.spec.trace_spec',
}
