package is.xyz.idle_openmw;

import android.app.Activity;
import android.graphics.Insets;
import android.graphics.Typeface;
import android.os.Build;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowInsets;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.GridLayout;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * The app's portrait chrome: the viewport, the stat strip and the command panel.
 *
 * THE SHAPE, and where it comes from
 * ----------------------------------
 * docs/app-ui.md specifies the layout top to bottom, and `crude ui mockupo.png` is the same design:
 *
 *   +-----------------------------+
 *   | the GAME (roughly the top   |   <- a wide, short render window: see VIEWPORT_SHARE
 *   | third), framed in gold      |
 *   +-----------------------------+
 *   | HP ====  MP ====  FT ====   |   <- thin lines, not chunky mobile bars
 *   +-----------------------------+
 *   | goal + why                  |
 *   |                             |
 *   | the command panel           |   <- the eleven tap-to-command buttons (built next)
 *   |                             |
 *   +-----------------------------+
 *
 * ONE view tree for both the real app and the emulator-only preview, because the alternative is two
 * layouts that drift. The only difference between them is what goes in the viewport: SDL's surface
 * when the engine is there, a placeholder card when it is not.
 *
 * WHY THE INSETS ARE HANDLED THE WAY THEY ARE
 * -------------------------------------------
 * docs/app-ui.md calls the status-bar inset out explicitly ("obvious on a phone with a notch").
 * Exactly one mechanism owns it, and which one depends on the API level:
 *
 *  - API 30+: the app takes the inset itself -- setDecorFitsSystemWindows(false) plus an
 *    OnApplyWindowInsetsListener that pads the root by systemBars|displayCutout. Taking it is what
 *    makes "is the status bar showing?" trackable: SDL's COMMAND_CHANGE_WINDOW_STYLE can hide the
 *    bars for a fullscreen engine, and when it does the insets report 0 and the chrome moves to the
 *    edges on its own (SDLActivity.java:776-791).
 *  - API 24-29: nothing here -- the platform insets the content view itself while the decor fits
 *    system windows, which is the state SDL's non-fullscreen flags restore
 *    (SDLActivity.java:787). A listener at this level would add a second inset on top (the classic
 *    double inset), so there deliberately is not one.
 *
 * Both devices this is aimed at (the API 34 emulator and a current phone) take the first path.
 */
public final class AppUi {

    /**
     * The share of the screen the game gets. docs/app-ui.md says "roughly the top third", and the
     * mockup measures about 34%. It is a fraction, not pixels, so it survives a resolution change.
     */
    public static final float VIEWPORT_SHARE = 0.34f;

    /**
     * The eleven commands of docs/app-ui.md, as (id, label) pairs.
     *
     * The IDs are the directive names the MOD already speaks (scripts/idle/directive.lua
     * GOAL_FOR): wait, go_town, roam, talk, rest and the window launchers. Three of them -- sneak,
     * attack, flee -- do not exist there yet and are the reason that table has to grow. The button id
     * is the contract between this UI and the mod, so the mod is where the meaning lives, never here.
     */
    public static final String[][] COMMANDS = {
            { "wait", "Wait" },
            { "go_town", "Go to Town" },
            { "roam", "Explore" },
            { "talk", "Talk" },
            { "sneak", "Sneak" },
            { "attack", "Attack" },
            { "flee", "Flee" },
            { "inventory", "Inventory" },
            { "journal", "Journal" },
            { "magic", "Magic" },
            { "rest", "Rest" },
    };

    /**
     * Typing into the engine's focused native widget (chargen name box, dialog OK). Set by
     * MainActivity only when the engine is loaded; null in the preview, where taps just log.
     */
    public interface EngineKeys {
        void replaceText(String text);
        void enter();
    }

    public static volatile EngineKeys keys;

    /** Dunmer-flavoured name suggestions for the adaptive name strip. */
    static final String[] NAMES = {
            "Nerevan", "Dralas", "Ilvi", "Sadri", "Athyn", "Mirisa", "Tedril", "Varvur",
            "Fenas", "Llevana", "Serjo", "Galsa", "Ondres", "Brara", "Rilvase", "Taren",
            "Aldyn", "Medyn", "Neloth", "Vivyne", "Hlaren", "Dreynis", "Uvren", "Selyn",
    };

    /** Where a tapped command goes. An interface, so the preview never has to touch SDL. */
    public interface CommandSink {
        void send(String json);
    }

    private AppUi() {
    }

    /** The pieces of the shell, so a caller can put things into it and update it. */
    public static final class Shell {

        public final ViewGroup root;
        public final FrameLayout viewport;
        public final LinearLayout statStrip;
        public final LinearLayout panel;

        private final TextView caption;
        private final TextView placeholder;
        private final TextView goalLine;
        private final TextView reasonLine;
        private final TextView lastOrder;
        // Not final: assigned by portraitColumn() while the view tree is built, not in the constructor.
        private TextView portrait;
        private final TextView footer;
        private final TextView logView;
        private final java.util.ArrayDeque<String> logLines = new java.util.ArrayDeque<>();
        private static final int LOG_LINES = 6;
        private final BarView health;
        private final BarView magic;
        private final BarView fatigue;
        private final TextView goldLine;
        private final Activity activity;
        private final CommandSink sink;
        private View grid;
        private LinearLayout chargenStrip;
        /** Which chargen screen the strip is built for ("" when the grid is showing). */
        private String stripFor = "";
        private String pickedName = "";
        private boolean imeOpen;
        /** Text strip stays up after the keyboard hides (e.g. after Type…) until Confirm. */
        private boolean textSticky;
        private Bridge.State lastState;
        private String lastSeen = "";
        private final java.util.Random random = new java.util.Random();

        private Shell(Activity activity, View gameView, CommandSink sink) {
            this.activity = activity;
            this.sink = sink;
            float scale = activity.getResources().getDisplayMetrics().density;

            LinearLayout frameRoot = new LinearLayout(activity);
            frameRoot.setOrientation(LinearLayout.VERTICAL);
            // The papyrus is the app's ground: it is what shows at the very top and bottom edges,
            // behind the system bars.
            frameRoot.setBackgroundDrawable(new Palette.Papyrus());
            // The two flexible children own the whole height, split 34/66.
            frameRoot.setWeightSum(100f);
            root = frameRoot;

            // --- the viewport: the game, or a card standing in for it ---
            FrameLayout frame = new FrameLayout(activity);
            frame.setBackgroundDrawable(Palette.frame(Palette.EBONY, Palette.GOLD, dp(scale, 3)));
            frame.setPadding(dp(scale, 3), dp(scale, 3), dp(scale, 3), dp(scale, 3));
            LinearLayout.LayoutParams frameParams = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, 0, VIEWPORT_SHARE * 100f);
            frameParams.setMargins(dp(scale, 8), dp(scale, 6), dp(scale, 8), 0);
            frame.setLayoutParams(frameParams);

            FrameLayout slot = new FrameLayout(activity);
            slot.setLayoutParams(new FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
            // A background of our own, so the placeholder and a not-yet-resumed SDL surface both
            // read as "the game window is here" rather than as a hole.
            slot.setBackgroundColor(Palette.EBONY_EDGE);
            frame.addView(slot);

            placeholder = text(activity, "Game view", Palette.DISABLED, 12f,
                    Typeface.BOLD, scale);
            placeholder.setGravity(Gravity.CENTER);
            placeholder.setLayoutParams(new FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
            frame.addView(placeholder);

            caption = text(activity, "", Palette.PARCHMENT, 11f, Typeface.NORMAL, scale);
            FrameLayout.LayoutParams captionParams = new FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
                    Gravity.BOTTOM | Gravity.START);
            captionParams.setMargins(dp(scale, 8), 0, dp(scale, 8), dp(scale, 6));
            caption.setLayoutParams(captionParams);
            caption.setShadowLayer(dp(scale, 2), 0f, 0f, 0xFF000000);
            frame.addView(caption);

            frameRoot.addView(frame);
            viewport = frame;

            if (gameView != null) {
                setGameView(gameView);
            }

            // --- the stat strip: H/M/F as thin lines ---
            statStrip = new LinearLayout(activity);
            statStrip.setOrientation(LinearLayout.HORIZONTAL);
            statStrip.setBackgroundDrawable(Palette.frame(Palette.EBONY, Palette.GOLD, dp(scale, 2)));
            statStrip.setPadding(dp(scale, 8), dp(scale, 5), dp(scale, 8), dp(scale, 5));
            LinearLayout.LayoutParams stripParams = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            stripParams.setMargins(dp(scale, 8), dp(scale, 6), dp(scale, 8), 0);
            statStrip.setLayoutParams(stripParams);

            health = addStat(statStrip, "HEALTH", Palette.HEALTH, scale);
            magic = addStat(statStrip, "MAGICKA", Palette.MAGIC, scale);
            fatigue = addStat(statStrip, "FATIGUE", Palette.FATIGUE, scale);

            goldLine = text(activity, "", Palette.TAN, 10f, Typeface.NORMAL, scale);
            goldLine.setGravity(Gravity.CENTER_VERTICAL | Gravity.END);
            LinearLayout.LayoutParams goldParams = new LinearLayout.LayoutParams(
                    0, ViewGroup.LayoutParams.WRAP_CONTENT, 0.9f);
            goldParams.setMargins(dp(scale, 8), 0, 0, 0);
            goldLine.setLayoutParams(goldParams);
            statStrip.addView(goldLine);

            frameRoot.addView(statStrip);

            // --- the command panel ---
            panel = new LinearLayout(activity);
            panel.setOrientation(LinearLayout.VERTICAL);
            panel.setBackgroundDrawable(Palette.frame(Palette.EBONY, Palette.GOLD, dp(scale, 2)));
            panel.setPadding(dp(scale, 10), dp(scale, 8), dp(scale, 10), dp(scale, 8));
            LinearLayout.LayoutParams panelParams = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, 0, (1f - VIEWPORT_SHARE) * 100f);
            panelParams.setMargins(dp(scale, 8), dp(scale, 6), dp(scale, 8), dp(scale, 6));
            panel.setLayoutParams(panelParams);

            goalLine = text(activity, "Waiting for the engine", Palette.PARCHMENT, 15f,
                    Typeface.BOLD, scale);
            panel.addView(goalLine);

            reasonLine = text(activity, "", Palette.TAN, 11f, Typeface.NORMAL, scale);
            panel.addView(reasonLine);

            // The row that matters: the command grid on the left, the character column on the right.
            LinearLayout body = new LinearLayout(activity);
            body.setOrientation(LinearLayout.HORIZONTAL);
            body.setLayoutParams(new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));
            grid = commandGrid(scale);
            body.addView(grid, new LinearLayout.LayoutParams(
                    0, ViewGroup.LayoutParams.MATCH_PARENT, 2.2f));
            chargenStrip = new LinearLayout(activity);
            chargenStrip.setOrientation(LinearLayout.VERTICAL);
            chargenStrip.setPadding(0, dp(scale, 6), dp(scale, 6), 0);
            chargenStrip.setVisibility(View.GONE);
            body.addView(chargenStrip, new LinearLayout.LayoutParams(
                    0, ViewGroup.LayoutParams.MATCH_PARENT, 2.2f));
            body.addView(portraitColumn(scale), new LinearLayout.LayoutParams(
                    0, ViewGroup.LayoutParams.MATCH_PARENT, 1f));
            panel.addView(body);

            lastOrder = text(activity, "", Palette.GOLD_BRIGHT, 10f, Typeface.NORMAL, scale);
            panel.addView(lastOrder);

            footer = text(activity, "", Palette.DISABLED, 10f, Typeface.NORMAL, scale);
            panel.addView(footer);

            frameRoot.addView(panel);

            // --- the log strip: ~6 lines of status under the buttons, so a failed engine start
            // still leaves something readable on screen (MainActivity / LogStrip feed it) ---
            logView = text(activity, "", Palette.PARCHMENT, 9f, Typeface.NORMAL, scale);
            logView.setTypeface(Typeface.MONOSPACE);
            logView.setLines(LOG_LINES);
            logView.setMaxLines(LOG_LINES);
            logView.setGravity(Gravity.BOTTOM | Gravity.START);
            logView.setEllipsize(null);
            logView.setHorizontallyScrolling(false);
            logView.setBackgroundDrawable(Palette.frame(Palette.EBONY, Palette.GOLD, dp(scale, 2)));
            logView.setPadding(dp(scale, 6), dp(scale, 4), dp(scale, 6), dp(scale, 4));
            LinearLayout.LayoutParams logParams = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            logParams.setMargins(dp(scale, 8), 0, dp(scale, 8), dp(scale, 6));
            logView.setLayoutParams(logParams);
            frameRoot.addView(logView);

            // Paint the bars and own the inset, so the chrome reads as one frame rather than as
            // papyrus behind grey.
            applyWindowPolicy(activity, frameRoot);
        }

        /**
         * The eleven command buttons, in a grid.
         *
         * docs/app-ui.md is emphatic about this being "tap-to-command buttons, not a joystick": the
         * player gives direction and the AI executes, so every control here is a verb, never a
         * direction. A TextView with a gold frame is used rather than an android.widget.Button
         * because a Button brings the platform's own theme with it -- holo/material chrome that would
         * be the only thing on this screen not made of papyrus and gold.
         */
        private View commandGrid(float scale) {
            GridLayout grid = new GridLayout(activity);
            grid.setColumnCount(3);
            grid.setRowCount((COMMANDS.length + 2) / 3);
            grid.setPadding(0, dp(scale, 6), dp(scale, 6), 0);

            for (String[] command : COMMANDS) {
                final String id = command[0];
                TextView button = text(activity, command[1], Palette.TAN, 12f, Typeface.BOLD, scale);
                button.setGravity(Gravity.CENTER);
                button.setBackgroundDrawable(Palette.frame(Palette.withAlpha(Palette.GOLD_BRIGHT, 26),
                        Palette.withAlpha(Palette.GOLD, 190), dp(scale, 1)));
                button.setClickable(true);
                button.setOnClickListener(new View.OnClickListener() {
                    @Override
                    public void onClick(View view) {
                        onCommandTap(id);
                    }
                });
                GridLayout.LayoutParams params = new GridLayout.LayoutParams(
                        GridLayout.spec(GridLayout.UNDEFINED, 1f),
                        GridLayout.spec(GridLayout.UNDEFINED, 1f));
                params.width = 0;
                params.height = 0;
                params.setMargins(dp(scale, 3), dp(scale, 3), dp(scale, 3), dp(scale, 3));
                grid.addView(button, params);
            }
            return grid;
        }

        /**
         * The character column. docs/app-ui.md asks for the portrait "exactly as Morrowind's own UI
         * shows it", which is the kx_ face parts assembled from the race/head/hair records -- engine
         * data Lua cannot reach, and a named engine-side job. What IS here is the part that makes a
         * portrait information rather than decoration: the state. A panel that reddens as the
         * character dies is worth more than a static face.
         */
        private View portraitColumn(float scale) {
            LinearLayout column = new LinearLayout(activity);
            column.setOrientation(LinearLayout.VERTICAL);
            column.setPadding(dp(scale, 8), dp(scale, 6), 0, 0);

            TextView heading = text(activity, "CHARACTER", Palette.GOLD_BRIGHT, 9f, Typeface.BOLD,
                    scale);
            column.addView(heading);

            portrait = text(activity, "healthy", Palette.PARCHMENT, 12f, Typeface.NORMAL, scale);
            portrait.setPadding(0, dp(scale, 6), 0, 0);
            column.addView(portrait);
            return column;
        }

        /** A command was tapped: tell the engine (if there is one) and say so on screen. */
        private void onCommandTap(String id) {
            // JSON by hand rather than with org.json: this is three fixed tokens with no user text in
            // it, and building an object to serialise three known keys is more machinery than value.
            String json = "{\"command\":\"" + id + "\"}";
            if (sink != null) {
                sink.send(json);
            }
            // Always visible, engine or not: the emulator preview has no engine, and a button that
            // does nothing visible would be indistinguishable from a broken one.
            lastOrder.setText("last order: " + id + "  ->  " + json);
        }

        /**
         * The adaptive strip: while the engine is asking a character-creation question the verb grid
         * is meaningless (the director holds until chargen ends), so it is swapped for buttons that
         * answer that question. Lua cannot name the character or press a native dialog's OK
         * (docs/chargen.md), so these type into the engine's focused widget via SDL text input.
         */
        private void adaptStrip(Bridge.State state) {
            if (state == null) {
                state = new Bridge.State();
            }
            lastState = state;
            String seen = state.screen + "/" + state.screenKind + "/" + state.phase + (imeOpen ? "/ime" : "");
            if (!seen.equals(lastSeen)) {
                lastSeen = seen;
                log("ui: screen=" + (state.screen.isEmpty() ? "-" : state.screen) + " kind="
                        + state.screenKind + " phase=" + state.phase + (state.live ? "" : " (fixture)")
                        + (imeOpen ? " keyboard=up" : ""));
            }
            // The soft keyboard is the one signal that cannot be lost: SDL raises it exactly when a
            // MyGUI edit box takes focus (the name prompt). Reported by the device: the keyboard came
            // up but the strip stayed on the verb grid because no ChargenName state had reached Java.
            // So the keyboard alone is enough to show the text strip.
            if (!state.inChargen() && (imeOpen || textSticky)) {
                Bridge.State text = new Bridge.State();
                text.screen = "ChargenName";
                text.screenKind = "chargen";
                text.phase = state.phase;
                text.phaseLabel = state.phaseLabel;
                state = text;
            }
            if (!state.inChargen()) {
                if (!stripFor.isEmpty()) {
                    stripFor = "";
                    chargenStrip.setVisibility(View.GONE);
                    grid.setVisibility(View.VISIBLE);
                }
                return;
            }
            String screen = state.screen == null || state.screen.isEmpty() ? "Chargen" : state.screen;
            if ("ChargenName".equals(screen)) {
                setGoal("Name your character", "Pick a name, reroll, or type one -- then Confirm.");
            } else {
                setGoal("Character creation", "Screen: " + screen.replace("Chargen", "")
                        + (state.phaseLabel.isEmpty() ? "" : "  (" + state.phaseLabel + ")"));
            }
            if (screen.equals(stripFor)) {
                return;
            }
            stripFor = screen;
            grid.setVisibility(View.GONE);
            chargenStrip.setVisibility(View.VISIBLE);
            buildChargenStrip(screen);
        }

        private void buildChargenStrip(String screen) {
            chargenStrip.removeAllViews();
            float scale = activity.getResources().getDisplayMetrics().density;
            if ("ChargenName".equals(screen)) {
                LinearLayout names = row(scale);
                for (int i = 0; i < 3; i++) {
                    final String name = NAMES[random.nextInt(NAMES.length)];
                    names.addView(stripButton(name, scale, new Runnable() {
                        @Override
                        public void run() {
                            pickName(name);
                        }
                    }), weighted(scale));
                }
                chargenStrip.addView(names, rowParams(scale));
                LinearLayout tools = row(scale);
                tools.addView(stripButton("Reroll", scale, new Runnable() {
                    @Override
                    public void run() {
                        buildChargenStrip("ChargenName");
                    }
                }), weighted(scale));
                tools.addView(stripButton("Random", scale, new Runnable() {
                    @Override
                    public void run() {
                        pickName(NAMES[random.nextInt(NAMES.length)]);
                    }
                }), weighted(scale));
                tools.addView(stripButton("Type\u2026", scale, new Runnable() {
                    @Override
                    public void run() {
                        promptName();
                    }
                }), weighted(scale));
                chargenStrip.addView(tools, rowParams(scale));
                LinearLayout confirm = row(scale);
                confirm.addView(stripButton("Confirm", scale, new Runnable() {
                    @Override
                    public void run() {
                        if (pickedName.isEmpty()) {
                            pickName(NAMES[random.nextInt(NAMES.length)]);
                        }
                        pressEnter("confirm name " + pickedName);
                        textSticky = false;
                        stripFor = "ChargenName";
                        adaptStrip(lastState);
                    }
                }), weighted(scale));
                chargenStrip.addView(confirm, rowParams(scale));
            } else {
                LinearLayout one = row(scale);
                one.addView(stripButton("Accept / Next", scale, new Runnable() {
                    @Override
                    public void run() {
                        pressEnter("accept " + stripFor);
                    }
                }), weighted(scale));
                chargenStrip.addView(one, rowParams(scale));
            }
        }

        private void pickName(String name) {
            pickedName = name;
            EngineKeys k = keys;
            if (k != null) {
                try {
                    k.replaceText(name);
                } catch (Throwable t) {
                    log("name entry failed: " + t);
                }
            }
            lastOrder.setText("name: " + name + "  (tap Confirm)");
        }

        private void pressEnter(String what) {
            EngineKeys k = keys;
            if (k != null) {
                try {
                    k.enter();
                } catch (Throwable t) {
                    log("enter failed: " + t);
                }
            }
            lastOrder.setText("last order: " + what);
        }

        private void promptName() {
            final android.widget.EditText input = new android.widget.EditText(activity);
            input.setSingleLine(true);
            input.setText(pickedName);
            new android.app.AlertDialog.Builder(activity)
                    .setTitle("Character name")
                    .setView(input)
                    .setPositiveButton("Use", new android.content.DialogInterface.OnClickListener() {
                        @Override
                        public void onClick(android.content.DialogInterface d, int w) {
                            String name = input.getText().toString().trim();
                            if (!name.isEmpty()) {
                                pickName(name);
                            }
                        }
                    })
                    .setNegativeButton("Cancel", null)
                    .show();
        }

        private LinearLayout row(float scale) {
            LinearLayout row = new LinearLayout(activity);
            row.setOrientation(LinearLayout.HORIZONTAL);
            return row;
        }

        private LinearLayout.LayoutParams rowParams(float scale) {
            return new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f);
        }

        private LinearLayout.LayoutParams weighted(float scale) {
            LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(
                    0, ViewGroup.LayoutParams.MATCH_PARENT, 1f);
            p.setMargins(dp(scale, 3), dp(scale, 3), dp(scale, 3), dp(scale, 3));
            return p;
        }

        private TextView stripButton(String label, float scale, final Runnable action) {
            TextView button = text(activity, label, Palette.TAN, 12f, Typeface.BOLD, scale);
            button.setGravity(Gravity.CENTER);
            button.setBackgroundDrawable(Palette.frame(Palette.withAlpha(Palette.GOLD_BRIGHT, 26),
                    Palette.withAlpha(Palette.GOLD, 190), dp(scale, 1)));
            button.setClickable(true);
            button.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View view) {
                    action.run();
                }
            });
            return button;
        }

        private BarView addStat(LinearLayout parent, String label, int colour, float scale) {
            LinearLayout column = new LinearLayout(activity);
            column.setOrientation(LinearLayout.VERTICAL);
            LinearLayout.LayoutParams columnParams = new LinearLayout.LayoutParams(
                    0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
            columnParams.setMargins(0, 0, dp(scale, 10), 0);
            column.setLayoutParams(columnParams);

            column.addView(text(activity, label, colour, 9f, Typeface.BOLD, scale));

            BarView bar = new BarView(activity, colour, Palette.withAlpha(Palette.PARCHMENT, 40),
                    dp(scale, 3));
            LinearLayout.LayoutParams barParams = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, dp(scale, 3));
            barParams.setMargins(0, dp(scale, 4), 0, 0);
            bar.setLayoutParams(barParams);
            column.addView(bar);

            parent.addView(column);
            return bar;
        }

        /** Put the game (or its stand-in) into the viewport, replacing anything already there. */
        public void setGameView(View game) {
            if (game == null) {
                return;
            }
            placeholder.setVisibility(View.GONE);
            FrameLayout slot = (FrameLayout) viewport.getChildAt(0);
            slot.removeAllViews();
            slot.addView(game, new FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        }

        /** Show the "no engine in this build" card explicitly rather than an empty frame. */
        public void setPlaceholder(String message) {
            placeholder.setText(message);
            placeholder.setVisibility(View.VISIBLE);
        }

        /** The viewport's caption -- `world`, `cell.current` (docs/app-ui.md). */
        public void setCaption(String text) {
            caption.setText(text == null ? "" : text);
        }

        /** The director's current goal, with the reason line it reports. */
        public void setGoal(String goal, String reason) {
            goalLine.setText(goal == null ? "" : goal);
            reasonLine.setText(reason == null ? "" : reason);
        }

        /** Pool fractions, 0..1. Out-of-range values are clamped by the bars themselves. */
        public void setPools(float healthFraction, float magickaFraction, float fatigueFraction) {
            health.setFraction(healthFraction);
            magic.setFraction(magickaFraction);
            fatigue.setFraction(fatigueFraction);
        }

        /** Gold, level and load, as one line. */
        public void setGold(String text) {
            goldLine.setText(text == null ? "" : text);
        }

        /** A dimmed line at the foot of the panel: build identity, engine state, hints. */
        /** Append one line to the on-screen log strip. Safe from any thread. */
        public void log(final String line) {
            if (line == null) return;
            activity.runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    logLines.addLast(line);
                    while (logLines.size() > LOG_LINES) logLines.removeFirst();
                    StringBuilder sb = new StringBuilder();
                    for (String l : logLines) {
                        if (sb.length() > 0) sb.append('\n');
                        sb.append(l);
                    }
                    logView.setText(sb.toString());
                }
            });
        }

        public void setFooter(String text) {
            footer.setText(text == null ? "" : text);
        }

        /** The panel's open space, for the command grid the play screen will build here. */
        public void addPanelBody(View view) {
            panel.addView(view, 1);
        }

        /**
         * Draw an engine state. This is the view's job, not the bridge's: Bridge holds the model and
         * knows nothing about widgets, which is what keeps "what the engine said" testable apart from
         * "how it looks".
         */
        /** The Android soft keyboard opened or closed (MainActivity watches the window insets). */
        public void setImeVisible(boolean visible) {
            if (visible == imeOpen) {
                return;
            }
            imeOpen = visible;
            if (visible) {
                textSticky = true;
            }
            adaptStrip(lastState);
        }

        public void applyState(Bridge.State state) {
            if (state == null) {
                return;
            }
            setGoal(state.goal, state.reason);
            adaptStrip(state);
            setCaption(state.caption);
            setPools(state.health, state.magicka, state.fatigue);
            setGold(state.gold);
            setPortraitState(state.health);
            setFooter(state.live
                    ? ("engine state " + state.bytes + " bytes")
                    : ("no engine: preview fixture, " + state.bytes + " bytes"));
        }

        /**
         * How the character is doing, in the same three states the rest of the mod talks about.
         *
         * The thresholds are NOT invented here: they are the configured ones the director acts on
         * (config thresholds.criticalHealth 0.25, lowHealth 0.5). The app does not get to have its
         * own opinion about when a character is in trouble -- that is exactly the "never re-derive
         * judgement from raw numbers" rule in docs/app-ui.md.
         */
        public void setPortraitState(float health) {
            String label;
            if (health <= 0.25f) {
                label = "critical";
            } else if (health <= 0.5f) {
                label = "wounded";
            } else {
                label = "healthy";
            }
            portrait.setText(label);
            portrait.setTextColor(health <= 0.25f ? Palette.HEALTH
                    : (health <= 0.5f ? Palette.TAN : Palette.PARCHMENT));
        }
    }

    /** Build the shell. `gameView` may be null -- the viewport then shows the placeholder card. */
    public static Shell create(Activity activity, View gameView) {
        return new Shell(activity, gameView, null);
    }

    /** Build the shell with somewhere to send tapped commands. */
    public static Shell create(Activity activity, View gameView, CommandSink sink) {
        return new Shell(activity, gameView, sink);
    }

    /**
     * Bar colours, the cutout mode, and the one inset mechanism this API level uses.
     *
     * The cutout mode is a {@link WindowManager.LayoutParams} field (API 28+) rather than the
     * `windowLayoutInDisplayCutoutMode` theme attribute, and that is what lets this app stay
     * resource-free: a theme attribute would need a `values/styles.xml`, and this APK compiles no
     * resource table at all.
     *
     * LAYOUT_IN_DISPLAY_CUTOUT_MODE_DEFAULT is stated explicitly so a later change cannot silently
     * put the viewport under the punch-hole camera.
     */
    @SuppressWarnings("deprecation")
    private static void applyWindowPolicy(Activity activity, View root) {
        Window window = activity.getWindow();
        window.setStatusBarColor(Palette.EBONY);
        window.setNavigationBarColor(Palette.EBONY);

        if (Build.VERSION.SDK_INT >= 28) {
            WindowManager.LayoutParams attributes = window.getAttributes();
            attributes.layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_DEFAULT;
            window.setAttributes(attributes);
        }

        if (Build.VERSION.SDK_INT >= 30) {
            window.setDecorFitsSystemWindows(false);
            root.setOnApplyWindowInsetsListener(new View.OnApplyWindowInsetsListener() {
                @Override
                public WindowInsets onApplyWindowInsets(View view, WindowInsets insets) {
                    Insets bars = insets.getInsets(
                            WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
                    view.setPadding(bars.left, bars.top, bars.right, bars.bottom);
                    return insets;
                }
            });
        }
    }

    private static int dp(float density, float value) {
        return Math.round(density * value);
    }

    /**
     * A sans/serif stand-in. Morrowind's own face is MysticCards, and the mod gets it for free from
     * the engine's UI font; a native Android view cannot name a font the app does not ship, and this
     * app ships no resources at all.
     */
    private static TextView text(Activity activity, String value, int colour, float sizeSp,
            int style, float scale) {
        TextView view = new TextView(activity);
        view.setText(value);
        view.setTextColor(colour);
        view.setTextSize(TypedValue.COMPLEX_UNIT_SP, sizeSp);
        view.setTypeface(Typeface.SERIF, style);
        view.setIncludeFontPadding(false);
        view.setLineSpacing(dp(scale, 3), 1f);
        return view;
    }
}
