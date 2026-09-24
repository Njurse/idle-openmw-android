@echo off
REM Create an arm64-v8a AVD so the arm64-v8a APK has a device to run on.
REM
REM The local idle_openmw AVD is x86_64 (android-34, google_apis) and cannot load an arm64 library,
REM so this makes a second one. Same semicolon-in-the-package-name reason as
REM install-arm64-image.bat for doing it from a file rather than a shell argument.
set SDK=%LOCALAPPDATA%\Android\Sdk
echo no | "%SDK%\cmdline-tools\latest\bin\avdmanager.bat" create avd ^
  --name idle_openmw_arm64 ^
  --package "system-images;android-28;google_apis;arm64-v8a" ^
  --device "pixel" ^
  --force
