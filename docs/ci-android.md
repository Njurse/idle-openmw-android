# Android CI

Workflow: `.github/workflows/android.yml`

Triggers: push to `main` touching `tools/android/**` or the workflow, tags `android-v*`, manual `workflow_dispatch`.

- **package** — JDK 17 + Android SDK (build-tools 34.0.0, android-34). Downloads `native-libs-arm64-v8a.zip`
  from the `native-libs` prerelease into `build/android-out/lib/arm64-v8a/`, fetches SDL2 2.30.12, runs
  `tools/android/build-apk.sh`, uploads the APK artifact. If the natives asset is missing it skips with a notice
  (the full engine build is too heavy for CI for now).
- **publish** — on `android-v*` tags attaches the APK to that release; always refreshes the rolling
  `android-dev` prerelease.
- **publish-existing** — manual run with `publish_existing=true` (optional `apk_url`) republishes an APK to `android-dev`.

To refresh natives: zip `build/android-out/lib/arm64-v8a/*.so` (flat) as `native-libs-arm64-v8a.zip` and
upload it to the `native-libs` release with `--clobber`.

Phone build: https://github.com/Njurse/idle-openmw-android/releases/download/android-dev/idle-openmw.apk