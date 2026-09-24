@echo off
REM Install an arm64 system image so the arm64-v8a APK has something to run on.
REM
REM Called through a batch file on purpose: the package name contains semicolons, and passing
REM "system-images;android-28;google_apis;arm64-v8a" through a POSIX shell into a .bat mangles it
REM every way I tried (the argument gets split, or the escape survives literally as a backslash).
REM A file has no such problem.
set SDK=%LOCALAPPDATA%\Android\Sdk
echo y | "%SDK%\cmdline-tools\latest\bin\sdkmanager.bat" --install "system-images;android-28;google_apis;arm64-v8a"
