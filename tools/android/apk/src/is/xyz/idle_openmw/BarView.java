package is.xyz.idle_openmw;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.view.View;

/**
 * One slim stat bar -- health, magicka or fatigue.
 *
 * docs/app-ui.md asks for "thin, elegant lines rather than chunky mobile bars, respecting the
 * original's minimalist HUD", so this draws a 3px track with a filled portion and nothing else: no
 * rounded caps, no gradient, no percentage label. The label and the number are the caller's TextViews
 * because a custom View that draws text would need a Typeface and a baseline it does not have.
 */
public final class BarView extends View {

    private final Paint track = new Paint();
    private final Paint fill = new Paint();
    private float fraction;

    public BarView(Context context, int fillColour, int trackColour, int thicknessPx) {
        super(context);
        track.setColor(trackColour);
        fill.setColor(fillColour);
        thicknessPx = Math.max(2, thicknessPx);
        setMinimumHeight(thicknessPx);
    }

    /** 0..1; anything outside is clamped, because a bad model must not paint off the bar. */
    public void setFraction(float value) {
        float clamped = value;
        if (Float.isNaN(clamped) || clamped < 0f) {
            clamped = 0f;
        }
        if (clamped > 1f) {
            clamped = 1f;
        }
        if (clamped != fraction) {
            fraction = clamped;
            invalidate();
        }
    }

    public float getFraction() {
        return fraction;
    }

    @Override
    protected void onDraw(Canvas canvas) {
        int w = getWidth();
        int h = getHeight();
        canvas.drawRect(0, 0, w, h, track);
        canvas.drawRect(0, 0, Math.round(w * fraction), h, fill);
    }
}
