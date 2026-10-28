package ui.activity;

/**
 * Holder for one native method only. libopenmw.so's Files::AndroidPath (components/files/androidpath.cpp)
 * exports Java_ui_activity_GameActivity_getPathToJni -- upstream's launcher class name -- and every
 * path it hands out is built from the two strings set here. Nothing called it in our app, so the
 * engine dereferenced null in SDL_main (SIGSEGV, "fault addr 0x0"). Keeping the upstream class name
 * means no engine rebuild is needed.
 */
public final class GameActivity {
    private GameActivity() {}

    /** global: its /files/config holds the global openmw.cfg; user: config/, saves/, data root. */
    public static native void getPathToJni(String global, String user);
}
