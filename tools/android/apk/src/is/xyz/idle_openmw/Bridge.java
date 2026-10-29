package is.xyz.idle_openmw;

import android.os.Handler;
import android.os.Looper;

import org.json.JSONException;
import org.json.JSONObject;

import java.nio.charset.StandardCharsets;

/**
 * The app side of the engine bridge: one place that holds what the engine last said.
 *
 * THE TWO DIRECTIONS
 * ------------------
 *   engine -> app   MainActivity.onEngineState(byte[]) is called by native code on the ENGINE's
 *                   script thread. This class turns those bytes into a {@link State} and posts it
 *                   to the UI thread. Nothing touches a View off the UI thread.
 *   app -> engine   MainActivity.sendCommand(json) hands bytes to native code, which queues them
 *                   for the mod (openmw.android.pollCommand(), see
 *                   tools/dev/engine-build/patches/0002-android-bridge.patch).
 *
 * WHY org.json IS FINE HERE
 * -------------------------
 * It ships with the platform, so using it costs no dependency and no resources -- which matters,
 * because this app compiles no resource table at all (tools/android/build-apk.sh). The alternative
 * (hand-splitting strings) is how a field name typo becomes a silently blank screen.
 *
 * A FAILURE NEVER THROWS. The engine is on the other side of this socket-like boundary and the app
 * is drawing the only thing the player can see; an exception in a posted runnable would take the
 * window down. Every read is optional and every parse failure lands in State.reason, where a human
 * can read it.
 */
public final class Bridge {

    /** The part of the engine report the shell draws today. Every field has a sane default. */
    public static final class State {
        public String goal = "waiting for the engine";
        public String reason = "no state has arrived yet";
        public String caption = "";
        public String gold = "Gold --   lvl --";
        public float health;
        public float magicka;
        public float fatigue;
        /** How many bytes the last report was, so the pipe can be seen working. */
        public int bytes;
        /** True when the bytes came from the engine, false when they are the {@link #FIXTURE}. */
        public boolean live;
        /** Lifecycle phase id from the mod ("world", "chargen", ...). */
        public String phase = "world";
        public String phaseLabel = "";
        /** The engine's top UI mode (e.g. "ChargenName") and its kind ("chargen", "world", ...). */
        public String screen = "";
        public String screenKind = "world";
        /** Nearby go-to buttons from the mod (appPayload places): each { id, label, kind }. */
        public java.util.List<String[]> places = new java.util.ArrayList<>();

        /** A stable key for the place list, so the strip is only rebuilt when it changes. */
        public String placesKey() {
            StringBuilder b = new StringBuilder();
            for (String[] p : places) {
                b.append(p[0]).append('|');
            }
            return b.toString();
        }

        /** True while the engine is asking a character-creation question. */
        public boolean inChargen() {
            return "chargen".equals(phase) || "chargen".equals(screenKind)
                    || (screen != null && screen.startsWith("Chargen"));
        }
    }

    /**
     * A canned engine report, matching the shape of the mod's own `ui` panel
     * (mods/idle_openmw/scripts/idleDirector.lua panel(): goal, goalReason, cell, player, status).
     *
     * WHY A FIXTURE IS SHIPPED IN THE APP RATHER THAN ONLY IN A TEST
     * The APK is arm64-v8a and QEMU2 will not emulate arm64 on an x86_64 host (docs/android.md), so
     * the emulator can never run the engine. Without a fixture the native shell could only ever be
     * seen empty on this machine -- and a UI you cannot see populated is a UI you cannot work on.
     * AppActivity feeds this through the SAME code path as the real engine, so what the emulator
     * shows is the real renderer with fake numbers, and the footer says which of the two it is.
     */
    public static final String FIXTURE = "{"
            + "\"goal\":\"fight\","
            + "\"goalReason\":\"a mudcrab is nearer than the shop\","
            + "\"mode\":\"auto\","
            + "\"phase\":\"world\","
            + "\"cell\":\"Seyda Neen\","
            + "\"places\":[{\"id\":\"door:arrille_s_tradehouse\",\"label\":\"Arrille's Tradehouse\",\"kind\":\"door\"},"
            + "{\"id\":\"door:census_and_excise_office\",\"label\":\"Census and Excise Office\",\"kind\":\"door\"},"
            + "{\"id\":\"talk:fargoth\",\"label\":\"Fargoth\",\"kind\":\"talk\"}],"
            + "\"player\":{\"gold\":1240,\"level\":5,\"encumbrance\":{\"current\":35,\"max\":90}},"
            + "\"status\":{\"healthFraction\":0.84,\"magickaFraction\":0.61,\"fatigueFraction\":0.72}"
            + "}";

    /** A single listener, because there is a single shell. */
    public interface Listener {
        void onEngineState(State state);
    }

    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private static volatile Listener sListener;
    private static volatile State sLatest;

    private Bridge() {
    }

    /** Register the shell (or a preview). Replays the latest state, so ordering never matters. */
    public static void listen(Listener listener) {
        sListener = listener;
        State latest = sLatest;
        if (latest != null) {
            post(listener, latest);
        }
    }

    /** Called from native code, on the engine's script thread. */
    public static void deliver(byte[] json) {
        deliver(new String(json, StandardCharsets.UTF_8), true);
    }

    /** For the preview fixture, and for anything else that wants to drive the UI without an engine. */
    public static void deliver(String json, boolean live) {
        post(sListener, parse(json, live));
    }

    private static void post(final Listener listener, final State state) {
        sLatest = state;
        if (listener == null) {
            return;
        }
        MAIN.post(new Runnable() {
            @Override
            public void run() {
                listener.onEngineState(state);
            }
        });
    }

    private static State parse(String json, boolean live) {
        State state = new State();
        state.live = live;
        if (json == null || json.isEmpty()) {
            state.reason = "the engine sent nothing";
            return state;
        }
        state.bytes = json.getBytes(StandardCharsets.UTF_8).length;
        try {
            JSONObject root = new JSONObject(json);
            state.goal = root.optString("goal", state.goal);
            state.reason = root.optString("goalReason", root.optString("reason", ""));
            state.caption = root.optString("cell", "");
            state.phase = root.optString("phase", state.phase);
            state.phaseLabel = root.optString("phaseLabel", "");
            state.screen = root.optString("screen", "");
            state.screenKind = root.optString("screenKind", state.screenKind);

            org.json.JSONArray places = root.optJSONArray("places");
            if (places != null) {
                for (int i = 0; i < places.length(); i++) {
                    JSONObject p = places.optJSONObject(i);
                    if (p == null || p.optString("id", "").isEmpty()) {
                        continue;
                    }
                    state.places.add(new String[] { p.optString("id"), p.optString("label", p.optString("id")),
                            p.optString("kind", "") });
                }
            }

            JSONObject player = root.optJSONObject("player");
            if (player != null) {
                int gold = player.optInt("gold", -1);
                int level = player.optInt("level", -1);
                state.gold = (gold >= 0 ? "Gold " + gold : "Gold --")
                        + "   lvl " + (level >= 0 ? String.valueOf(level) : "--");
            }

            JSONObject status = root.optJSONObject("status");
            if (status != null) {
                state.health = (float) status.optDouble("healthFraction", 0);
                state.magicka = (float) status.optDouble("magickaFraction", 0);
                state.fatigue = (float) status.optDouble("fatigueFraction", 0);
            }
        } catch (JSONException e) {
            // Say so rather than drawing zeros: a blank screen that means "unparseable" is the
            // failure mode that costs an afternoon.
            state.reason = "unreadable engine state: " + e.getMessage();
        }
        return state;
    }
}
