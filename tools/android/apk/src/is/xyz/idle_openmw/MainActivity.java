package is.xyz.idle_openmw;

import android.os.Bundle;
import android.view.ViewGroup;
import android.view.ViewParent;

import org.libsdl.app.SDLActivity;

/**
 * The app's real activity: SDL2's own, told to start our engine -- and then told where to put it.
 *
 * WHY THIS IS AN SDLActivity SUBCLASS
 * -----------------------------------
 * OpenMW's Android build produces a SHARED LIBRARY, not an executable -- the engine's entry point is
 * `extern "C" int SDL_main(int, char**)` (apps/openmw/main.cpp:238) -- and SDL2's SDLActivity is the
 * supported thing that loads such a library and calls that symbol. So the app is this class plus an
 * engine.
 *
 * SDL2 IS LINKED INTO libopenmw.so STATICALLY. That is why getLibraries() names only "openmw" and
 * not "SDL2": there is no separate libSDL2.so to load, and the JNI bridge it needs
 * (Java_org_libsdl_app_SDLActivity_*) is exported from libopenmw.so -- verified with llvm-nm. If
 * that ever stops being true the failure is a JNI UnsatisfiedLinkError at launch, so the exported
 * symbols, not this file, are the thing to check.
 *
 * WHY IT REPARENTS THE SURFACE
 * ----------------------------
 * SDLActivity makes a RelativeLayout, puts its SDLSurface in it and calls setContentView on that
 * layout (SDLActivity.java:396-415) -- a full-screen game. This app wants the game in a FRAMED
 * VIEWPORT across the top third, with the mod's own controls below it (docs/app-ui.md).
 *
 * The hook is the superclass's own fields: `mSurface` and `mLayout` are `protected static`
 * (SDLActivity.java:212,215), so a subclass can reach them. We move `mLayout` -- the whole
 * RelativeLayout, not just the surface -- because SDL adds its soft-keyboard `mTextEdit` to
 * `mLayout` later (SDLActivity.java:1278); moving the container keeps that working, moving the
 * surface alone would strand it.
 *
 * WHICH ACTIVITY STARTS THIS ONE is {@link LauncherActivity}'s business -- it picks between this and
 * {@link AppActivity} depending on whether the engine is packaged.
 */
public class MainActivity extends SDLActivity {

    private AppUi.Shell shell;

    // -----------------------------------------------------------------------------------------
    // The native boundary. These two names are the JNI mangling the engine's fork patch defines
    // (tools/dev/engine-build/patches/0002-android-bridge.patch,
    // apps/openmw/mwlua/androidbindings.cpp): Java_is_xyz_idle_openmw_MainActivity_nativeBridgeAttach
    // and ..._nativeCommand. Renaming either method -- or moving them off MainActivity -- breaks the
    // link at RUNTIME (UnsatisfiedLinkError on first call), not at build time, so the symbols in
    // libopenmw.so are the thing to check, not this file.
    // -----------------------------------------------------------------------------------------

    /// Hand native code the VM and the callback to use. Called AFTER super.onCreate, because that is
    /// what loads libopenmw.so and makes these declarations resolvable at all.
    private static native void nativeBridgeAttach();

    /// One command for the mod, as UTF-8 JSON bytes.
    private static native void nativeCommand(byte[] json);

    private static boolean sEngineAttached;

    /** Engine -> app. Called by native code on the engine's script thread. */
    public static void onEngineState(byte[] json) {
        Bridge.deliver(json);
    }

    /** App -> engine. A no-op before the engine has attached, so a UI tap cannot crash the app. */
    public static void sendCommand(String json) {
        if (sEngineAttached && json != null) {
            nativeCommand(json.getBytes(java.nio.charset.StandardCharsets.UTF_8));
        }
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        // The GLES/gl4es environment upstream's launcher (ui.activity.GameActivity) exports before SDL_main.
        // libGL.so is gl4es; without these OSG gets no usable GL and SDL_main segfaults after settings load.
        try {
            android.system.Os.setenv("OPENMW_GLES_VERSION", "2", true);
            android.system.Os.setenv("LIBGL_ES", "2", true);
            android.system.Os.setenv("LIBGL_GL", "21", true);
            android.system.Os.setenv("OSG_VERTEX_BUFFER_HINT", "VBO", true);
            android.system.Os.setenv("OSG_TEXT_SHADER_TECHNIQUE", "NO_TEXT_SHADER", true);
            android.system.Os.setenv("LIBGL_NOTEXRECT", "1", true);
        } catch (android.system.ErrnoException ignored) {
        }
        super.onCreate(savedInstanceState);

        // Engine paths, before SDL_main can run (it starts on surface-ready, after onCreate). Both point at
        // internal app storage (/data/data/<pkg>/files): the engine can read it, and a debuggable build is
        // staged with `adb shell run-as` (files adb pushes into Android/data are shell-owned and unreadable):
        //   <ext>/files/config/openmw.cfg + defaults.bin, <ext>/files/resources, saves under <ext>/files.
        if (SDLActivity.mLayout != null) {
            java.io.File ext = getFilesDir();
            if (ext != null) {
                new java.io.File(ext, "config").mkdirs();
                ui.activity.GameActivity.getPathToJni(ext.getParent(), ext.getAbsolutePath());
            }
        }

        ViewGroup sdlLayout = SDLActivity.mLayout;
        if (sdlLayout == null) {
            // SDL found the file but could not load it (a missing dependency, a JNI mismatch). It
            // has already raised its own AlertDialog; show the shell and say so here too, because
            // the dialog is easy to miss -- the process stays alive behind it and the app LOOKS
            // started (docs/android.md, Finding C).
            shell = AppUi.create(this, null);
            shell.setPlaceholder("Game view\n\n(the engine failed to load)");
            shell.setGoal("Engine failed to load",
                    "libopenmw.so is present but SDL could not start it -- see the dialog and the log.");
            setContentView(shell.root);
            return;
        }

        // Detach SDL's layout from the window's content container first: a ViewGroup refuses a child
        // that still has a parent.
        ViewParent parent = sdlLayout.getParent();
        if (parent instanceof ViewGroup) {
            ((ViewGroup) parent).removeView(sdlLayout);
        }

        // A sink, not a direct call into SDL: in the UI-only build there is no engine, and the preview
        // must not have to load the SDL class to draw a grid of buttons.
        shell = AppUi.create(this, sdlLayout, new AppUi.CommandSink() {
            @Override
            public void send(String json) {
                MainActivity.sendCommand(json);
            }
        });
        shell.setCaption("the game renders here");
        shell.setGoal("Waiting for the first tick",
                "The engine is up; the director's goal arrives with the first snapshot.");
        shell.setFooter("idle-openmw  0.52  arm64");
        setContentView(shell.root);

        // Now that there is a shell to draw into, open the bridge. Order matters: attach() caches
        // the method id it will call, and listen() is what routes what it calls into the views.
        Bridge.listen(new Bridge.Listener() {
            @Override
            public void onEngineState(Bridge.State state) {
                shell.applyState(state);
            }
        });
        nativeBridgeAttach();
        sEngineAttached = true;
    }

    /** The shell, for a later phase to bind model data into. */
    public AppUi.Shell shell() {
        return shell;
    }

    /**
     * The game lives in a short, WIDE viewport inside a portrait activity. SDL would otherwise (a) skip
     * a surface wider than tall while the activity requests PORTRAIT ("Skip .. Surface is not ready",
     * so SDL_main never starts) -- avoided by userPortrait in the manifest -- and (b) rotate the whole
     * activity to landscape to match the window's aspect. The shell owns orientation, so ignore it.
     */
    @Override
    public void setOrientationBis(int w, int h, boolean resizable, String hint) {
        // intentionally empty: stay portrait
    }

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
