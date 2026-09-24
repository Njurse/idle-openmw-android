package is.xyz.idle_openmw;

import org.libsdl.app.SDLActivity;

/**
 * The app's only activity: SDL2's own, told to start our engine.
 *
 * WHY THIS IS SO SHORT
 * --------------------
 * OpenMW's Android build produces a SHARED LIBRARY, not an executable -- the engine's entry point
 * is `extern "C" int SDL_main(int, char**)` (apps/openmw/main.cpp:238) -- and SDL2's SDLActivity is
 * the supported thing that loads such a library and calls that symbol. So the whole app is this
 * class plus an engine.
 *
 * SDL2 IS LINKED INTO libopenmw.so STATICALLY. That is why getLibraries() names only "openmw" and
 * not "SDL2": there is no separate libSDL2.so to load, and the JNI bridge it needs
 * (Java_org_libsdl_app_SDLActivity_*) is exported from libopenmw.so -- verified with llvm-nm:
 *
 *   T JNI_OnLoad
 *   T Java_org_libsdl_app_SDLActivity_nativeAddTouch
 *   T Java_org_libsdl_app_SDLActivity_nativeFocusChanged
 *   ...
 *
 * If that ever stops being true the failure is a JNI UnsatisfiedLinkError at launch, so the
 * exported symbols, not this file, are the thing to check.
 */
public class MainActivity extends SDLActivity {

    @Override
    protected String[] getLibraries() {
        return new String[] { "openmw" };
    }

    @Override
    protected String getMainSharedObject() {
        return getContext().getApplicationInfo().nativeLibraryDir + "/libopenmw.so";
    }

    @Override
    protected String getMainFunction() {
        return "SDL_main";
    }
}
