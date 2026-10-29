package org.libsdl.app;

import android.view.KeyEvent;

/**
 * Typing into the engine without a keyboard. Lives in SDL's package because SDLInputConnection (the
 * class whose nativeCommitText turns a string into SDL_TEXTINPUT events) is package-private.
 *
 * Used by the adaptive button strip for chargen: Lua has no API to name the character or press a
 * native dialog's OK (docs/chargen.md), so the shell types into the engine's own focused edit box.
 */
public final class IdleInput {
    private IdleInput() {
    }

    public static void key(int keycode) {
        SDLActivity.onNativeKeyDown(keycode);
        SDLActivity.onNativeKeyUp(keycode);
    }

    /** Clear the focused field, type text into it. */
    public static void replaceText(String text) {
        for (int i = 0; i < 32; i++) key(KeyEvent.KEYCODE_DEL);
        if (text != null && !text.isEmpty()) SDLInputConnection.nativeCommitText(text, 1);
    }

    public static void enter() {
        key(KeyEvent.KEYCODE_ENTER);
    }
}
