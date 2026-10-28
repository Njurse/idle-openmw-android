package is.xyz.idle_openmw;

import android.app.Activity;
import android.os.Bundle;

/**
 * The UI without the engine: the shell on its own, for a device that cannot run libopenmw.so.
 *
 * WHY THIS ACTIVITY EXISTS AT ALL
 * -------------------------------
 * The APK is arm64-v8a because that is what the published OpenMW Android dependency archive is, and
 * a host-emulated arm64 device is not available: QEMU2 refuses `Avd's CPU Architecture 'arm64' is
 * not supported ... on x86_64 host` (docs/android.md). So the local AVD -- Android 14, x86_64, 4 KB
 * pages, `idle_openmw` -- can never load the engine.
 *
 * It CAN run this. Same Java, same view tree, same papyrus and gold: everything except the engine.
 * That is what makes the UI itself reviewable from this machine instead of only on a phone, which is
 * the whole point of "test from within there" (docs/status.md).
 *
 * It cannot be folded into {@code MainActivity}: SDLActivity.onCreate has no path that skips the
 * native library load (SDLActivity.java:334-379 -- a failed load raises an AlertDialog and returns
 * before setContentView), and a Java subclass cannot call past its superclass to Activity.onCreate.
 * Two activities is the honest way to have two starts.
 */
public class AppActivity extends Activity {

    private AppUi.Shell shell;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        shell = AppUi.create(this, null, new AppUi.CommandSink() {
            @Override
            public void send(String json) {
                // No engine in this build: the order is real (it is what WOULD go over the bridge), it
                // just has nowhere to go. Logging it keeps the tap path honest rather than silent.
                android.util.Log.i("IdleOpenMW", "command (no engine attached): " + json);
            }
        });
        shell.setPlaceholder("Game view\n\n(this build carries no engine)");
        shell.setCaption("no engine in this build");
        shell.setGoal("UI preview",
                "This is the UI-only build: no libopenmw.so is packaged, so the viewport shows a "
                        + "placeholder instead of the game.");
        shell.setGold("Gold --   lvl --");

        setContentView(shell.root);

        // Drive the shell with the SAME path the engine uses, so what an emulator screenshot shows
        // is the real renderer holding fake numbers. The footer names the difference
        // (Bridge.State.live), because a fixture that looks like live data is a trap.
        Bridge.listen(new Bridge.Listener() {
            @Override
            public void onEngineState(Bridge.State state) {
                shell.applyState(state);
            }
        });
        Bridge.deliver(Bridge.FIXTURE, false);
    }

    /** The shell, so a driver (adb, an instrumentation test) can push values into it. */
    public AppUi.Shell shell() {
        return shell;
    }
}
