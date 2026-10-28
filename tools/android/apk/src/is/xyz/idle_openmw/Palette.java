package is.xyz.idle_openmw;

import android.graphics.Bitmap;
import android.graphics.BitmapShader;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.ColorFilter;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.PixelFormat;
import android.graphics.Rect;
import android.graphics.Shader;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;

import java.util.Random;

/**
 * The app's colours, borders and the papyrus texture.
 *
 * WHY THE NUMBERS ARE WHAT THEY ARE
 * ---------------------------------
 * The first block is Morrowind's own GMST font colours, verbatim, as OpenMW ships them in
 * `files/openmw.cfg` (`fallback=FontColor_color_*`). They are the SAME numbers as
 * `mods/idle_openmw/scripts/idle/theme.lua` M.PALETTE and as `docs/theme.md` -- that file is the
 * source of truth for anything the mod also paints, and these are its mirror. The app and the mod
 * must not drift (docs/app-ui.md), so if a value changes there it changes here too. Phase 3 of the
 * plan replaces the hard-coded copies with the palette the mod publishes over the bridge.
 *
 * The second block is the app's own chrome per docs/app-ui.md: warm textured papyrus, near-black
 * "ebony" panel interiors, gold-orange trim.
 *
 * No resources are used anywhere in this app (see tools/android/build-apk.sh -- it runs
 * javac/d8/aapt2 and compiles no resource table), so every colour lives in code rather than in a
 * `colors.xml`.
 */
public final class Palette {

    private Palette() {
    }

    // --- Morrowind's UI colours (mirror of scripts/idle/theme.lua) ---------------------------------

    /** The Morrowind tan -- `FontColor_color_normal`. */
    public static final int TAN = argb(202, 165, 96);
    /** Parchment: headers and hover text -- `FontColor_color_normal_over` / `_header`. */
    public static final int PARCHMENT = argb(223, 201, 159);
    /** Dimmed / secondary text -- `FontColor_color_disabled`. */
    public static final int DISABLED = argb(179, 168, 135);
    /** `FontColor_color_negative` / `_health`. */
    public static final int HEALTH = argb(200, 60, 30);
    /** `FontColor_color_magic`. */
    public static final int MAGIC = argb(53, 69, 159);
    /** `FontColor_color_fatigue`. */
    public static final int FATIGUE = argb(0, 150, 60);

    // --- The app's own chrome (docs/app-ui.md) -----------------------------------------------------

    /** The papyrus: yellowed, orange-flecked. Two tones, blended by {@link Papyrus}. */
    public static final int PAPYRUS_LIGHT = argb(236, 214, 163);
    public static final int PAPYRUS_DARK = argb(198, 154, 84);
    /** Dark leather / ebony: the panel interiors, echoing the inventory and dialogue windows. */
    public static final int EBONY = argb(26, 21, 14);
    public static final int EBONY_EDGE = argb(44, 35, 22);
    /** The signature Morrowind trim. */
    public static final int GOLD = argb(197, 146, 57);
    public static final int GOLD_BRIGHT = argb(232, 183, 92);
    /** Ink on vellum -- text drawn straight onto the papyrus rather than onto a dark panel. */
    public static final int INK = argb(72, 51, 22);

    /** Alpha-blended ARGB. */
    public static int argb(int r, int g, int b) {
        return Color.argb(255, r, g, b);
    }

    /** The same colour at a given 0..255 alpha -- used for panel washes and hairline strokes. */
    public static int withAlpha(int colour, int alpha) {
        return (colour & 0x00FFFFFF) | ((alpha & 0xFF) << 24);
    }

    /**
     * A gold-framed panel: a filled background with a stroke, as a 9-slice-free
     * {@link GradientDrawable}.
     *
     * The stroke is what makes a panel read as one of Morrowind's own windows, so it is worth the
     * four characters it costs to keep it in one place.
     */
    public static Drawable frame(int fill, int stroke, int strokeWidthPx) {
        GradientDrawable d = new GradientDrawable();
        d.setColor(fill);
        d.setStroke(strokeWidthPx, stroke);
        return d;
    }

    /** A hairline divider, drawn as a 1-2px filled bar. */
    public static Drawable rule(int colour, int heightPx) {
        GradientDrawable d = new GradientDrawable();
        d.setColor(colour);
        d.setSize(1, heightPx);
        return d;
    }

    /**
     * The papyrus background: a vertical tone gradient with a deterministic speckle on top.
     *
     * It is a Drawable rather than a bitmap so it re-tiles to whatever the view is; the speckle is
     * seeded so two runs (and two screenshots) are byte-identical, which is the only way a visual
     * diff of the emulator screenshots can mean anything.
     */
    public static final class Papyrus extends Drawable {

        private static final int TILE = 96;
        private static final int SPECKLES = 1500;

        private final Paint base = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint grain = new Paint(Paint.ANTI_ALIAS_FLAG);
        private int lastWidth = -1;
        private int lastHeight = -1;

        public Papyrus() {
            grain.setShader(speckleShader());
        }

        private static BitmapShader speckleShader() {
            Bitmap tile = Bitmap.createBitmap(TILE, TILE, Bitmap.Config.ARGB_8888);
            Canvas c = new Canvas(tile);
            Paint p = new Paint();
            // Deterministic: java.util.Random with a fixed seed, NOT Math.random. An unstable
            // texture would make two screenshots of the same screen differ.
            Random rng = new Random(20240812L);
            for (int i = 0; i < SPECKLES; i++) {
                int x = rng.nextInt(TILE);
                int y = rng.nextInt(TILE);
                int roll = rng.nextInt(100);
                if (roll < 66) {
                    // fibre: a faint dark fleck
                    p.setColor(withAlpha(INK, 10 + rng.nextInt(18)));
                    c.drawPoint(x, y, p);
                } else if (roll < 92) {
                    // age spot: slightly darker, larger
                    p.setColor(withAlpha(argb(150, 108, 52), 10 + rng.nextInt(14)));
                    c.drawRect(x, y, x + 1 + rng.nextInt(3), y + 1 + rng.nextInt(3), p);
                } else {
                    // a bleached fleck, so the texture does not read as dirt
                    p.setColor(withAlpha(argb(252, 242, 214), 12 + rng.nextInt(16)));
                    c.drawPoint(x, y, p);
                }
            }
            return new BitmapShader(tile, Shader.TileMode.REPEAT, Shader.TileMode.REPEAT);
        }

        @Override
        public void draw(Canvas canvas) {
            Rect bounds = getBounds();
            if (bounds.width() != lastWidth || bounds.height() != lastHeight) {
                lastWidth = bounds.width();
                lastHeight = bounds.height();
                base.setShader(new LinearGradient(bounds.left, bounds.top, bounds.left, bounds.bottom,
                        PAPYRUS_LIGHT, PAPYRUS_DARK, Shader.TileMode.CLAMP));
            }
            canvas.drawRect(bounds, base);
            canvas.drawRect(bounds, grain);
        }

        @Override
        public void setAlpha(int alpha) {
        }

        @Override
        public void setColorFilter(ColorFilter filter) {
        }

        @Override
        public int getOpacity() {
            return PixelFormat.OPAQUE;
        }
    }
}
