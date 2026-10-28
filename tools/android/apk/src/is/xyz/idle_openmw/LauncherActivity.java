package is.xyz.idle_openmw;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;

import java.io.File;

/**
 * The launcher: pick which of the two real activities to start, then get out of the way.
 *
 * WHY THIS EXISTS, RATHER THAN AN `if` INSIDE MainActivity
 * --------------------------------------------------------
 * The first version of this app tested for the engine at the top of MainActivity.onCreate and, when
 * it was missing, called startActivity(AppActivity) and finish() without calling through to
 * super.onCreate. That throws:
 *
 *   android.util.SuperNotCalledException: Activity {is.xyz.idle_openmw/is.xyz.idle_openmw.MainActivity}
 *   did not call through to super.onCreate()
 *
 * The framework sets a flag in Activity.onCreate and checks it after the call returns
 * (ActivityThread.performLaunchActivity); a subclass cannot skip its superclass to reach the
 * grandparent, so MainActivity cannot be "SDLActivity, or not, depending on the device".
 *
 * A separate Activity can. This one extends Activity directly for exactly that reason, decides, and
 * finishes. It sets no content view, so there is nothing to flash: the system's starting window
 * covers the gap.
 */
public class LauncherActivity extends Activity {

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        boolean engine = new File(getApplicationInfo().nativeLibraryDir, "libopenmw.so").isFile();
        // With the engine: it needs Morrowind's data and the unpacked resources first, or SDL_main dies
        // (the old crash). SetupActivity asks for the data, writes openmw.cfg, then starts MainActivity.
        Class<?> next = !engine ? AppActivity.class
                : SetupActivity.isReady(this) ? MainActivity.class : SetupActivity.class;
        startActivity(new Intent(this, next));
        finish();
    }
}
