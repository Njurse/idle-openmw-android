package is.xyz.idle_openmw;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.provider.DocumentsContract;
import android.provider.Settings;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/**
 * First-run setup: find Morrowind's data, unpack the engine's resources, write openmw.cfg, and only
 * THEN start the engine.
 *
 * WHY: the engine used to start straight away with no data path and no resources directory (the APK
 * shipped no assets), and SDL_main died. Native OpenMW opens files with plain paths, so the data has
 * to be on a real filesystem path the app can read -- a SAF content:// tree is not enough on its own.
 *
 * WHERE DATA CAN LIVE (checked in this order)
 *   1. Android/data/is.xyz.idle_openmw/files/Morrowind   -- app-specific, needs NO permission
 *   2. /storage/emulated/0/Morrowind                      -- needs All-files access on Android 11+
 *   3. any folder picked with "Choose folder..."           -- resolved to a real path; may need access
 * The folder is the one containing `Data Files` (and normally Morrowind.ini). Picking `Data Files`
 * itself is accepted too.
 *
 * WHAT IT WRITES (files dir = /data/user/0/is.xyz.idle_openmw/files, which MainActivity hands the
 * engine as both the global and user path, so config resolves to files/config)
 *   files/resources/...          engine resources (assets/openmw/resources)
 *   files/mods/idle_openmw/...   the idle mod
 *   files/config/defaults.bin    settings defaults
 *   files/config/openmw.cfg      the base cfg with absolute resources=/data= plus our data/content
 */
public class SetupActivity extends Activity {

    static final String PREFS = "setup";
    static final String KEY_ROOT = "data_root";
    static final String KEY_PENDING = "pending_root";
    static final String KEY_STAMP = "assets_stamp";
    private static final int REQ_TREE = 41;

    private TextView status;
    private Button grantButton;
    private volatile boolean busy;

    /** True when a validated root is saved, its data is still readable, and assets are current. */
    static boolean isReady(Context c) {
        SharedPreferences p = c.getSharedPreferences(PREFS, MODE_PRIVATE);
        String root = p.getString(KEY_ROOT, null);
        if (root == null || findDataFiles(new File(root)) == null) return false;
        if (p.getLong(KEY_STAMP, -1) != stamp(c)) return false;
        return new File(c.getFilesDir(), "config/openmw.cfg").isFile()
                && new File(c.getFilesDir(), "resources/vfs").isDirectory();
    }

    private static long stamp(Context c) {
        try {
            return c.getPackageManager().getPackageInfo(c.getPackageName(), 0).lastUpdateTime;
        } catch (Exception e) {
            return 0;
        }
    }

    /** Child of dir whose name matches (case-insensitively), or null. */
    private static File child(File dir, String... names) {
        File[] kids = dir.listFiles();
        if (kids == null) return null;
        for (String n : names)
            for (File k : kids)
                if (k.getName().equalsIgnoreCase(n)) return k;
        return null;
    }

    /**
     * The `Data Files` directory for a root, or null if this is not a Morrowind install. Valid means
     * a `Data Files`/`DataFiles` dir holding Morrowind.esm (or the root itself being that dir).
     * Morrowind.ini is NOT required: the bundled base cfg already carries the fallback= values the
     * ini importer would produce, so a GOG/Steam copy without the ini still works.
     */
    static File findDataFiles(File root) {
        if (root == null || !root.isDirectory()) return null;
        File df = child(root, "Data Files", "DataFiles");
        if (df != null && df.isDirectory() && child(df, "Morrowind.esm") != null) return df;
        if (child(root, "Morrowind.esm") != null) return root;
        return null;
    }

    private List<File> candidates() {
        List<File> out = new ArrayList<>();
        File ext = getExternalFilesDir(null);
        if (ext != null) out.add(new File(ext, "Morrowind"));
        File shared = Environment.getExternalStorageDirectory();
        out.add(new File(shared, "Morrowind"));
        out.add(new File(shared, "Syncthing/Morrowind"));
        out.add(new File(shared, "Android/data/is.xyz.idle_openmw/files/Morrowind"));
        out.add(new File(shared, "Games/Morrowind"));
        out.add(new File(shared, "Download/Morrowind"));
        return out;
    }

    private static boolean haveAllFiles() {
        if (Build.VERSION.SDK_INT >= 30) return Environment.isExternalStorageManager();
        return true;
    }

    private int dp(int v) {
        return (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, getResources().getDisplayMetrics());
    }

    private TextView text(String s, int sp, int colour) {
        TextView t = new TextView(this);
        t.setText(s);
        t.setTextSize(sp);
        t.setTextColor(colour);
        t.setPadding(0, dp(6), 0, dp(6));
        return t;
    }

    private Button button(String label, View.OnClickListener l) {
        Button b = new Button(this);
        b.setText(label);
        b.setAllCaps(false);
        b.setTextColor(Palette.GOLD_BRIGHT);
        b.setBackground(Palette.frame(Palette.EBONY, Palette.GOLD, dp(2)));
        b.setOnClickListener(l);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.topMargin = dp(10);
        b.setLayoutParams(lp);
        return b;
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);
        col.setPadding(dp(22), dp(36), dp(22), dp(22));

        TextView title = text("Idle OpenMW", 28, Palette.INK);
        title.setGravity(Gravity.CENTER_HORIZONTAL);
        col.addView(title);
        col.addView(text("Where is your Morrowind?", 18, Palette.INK));

        LinearLayout panel = new LinearLayout(this);
        panel.setOrientation(LinearLayout.VERTICAL);
        panel.setPadding(dp(14), dp(10), dp(14), dp(10));
        panel.setBackground(Palette.frame(Palette.EBONY, Palette.GOLD, dp(2)));
        panel.addView(text("Choose the folder that contains BOTH Morrowind.ini and \"Data Files\" "
                + "(not Data Files itself). Copy it from your PC install.\n\n"
                + "Easiest, no permission needed: copy it to\n"
                + "Android/data/is.xyz.idle_openmw/files/Morrowind\n\n"
                + "Or put it at /storage/emulated/0/Morrowind (or anywhere) and grant All-files "
                + "access so the engine can read it.", 14, Palette.PARCHMENT));
        status = text("", 14, Palette.TAN);
        panel.addView(status);
        col.addView(panel);

        col.addView(button("Choose folder\u2026", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                Intent i = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE);
                i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION);
                try {
                    startActivityForResult(i, REQ_TREE);
                } catch (Exception e) {
                    setStatus("No folder picker on this device: " + e);
                }
            }
        }));
        grantButton = button("Grant all-files access", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                requestAllFiles();
            }
        });
        col.addView(grantButton);
        col.addView(button("Check again", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                detect();
            }
        }));

        // Make the app-specific drop folder exist so it shows up in file managers / over USB.
        File ext = getExternalFilesDir(null);
        if (ext != null) new File(ext, "Morrowind").mkdirs();

        ScrollView scroll = new ScrollView(this);
        scroll.setBackground(new Palette.Papyrus());
        scroll.addView(col);
        setContentView(scroll);
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (grantButton != null)
            grantButton.setVisibility(Build.VERSION.SDK_INT >= 30 && !haveAllFiles() ? View.VISIBLE : View.GONE);
        detect();
    }

    private void setStatus(final String s) {
        runOnUiThread(new Runnable() {
            @Override
            public void run() {
                status.setText(s);
            }
        });
    }

    private void requestAllFiles() {
        if (Build.VERSION.SDK_INT < 30) {
            if (Build.VERSION.SDK_INT >= 23)
                requestPermissions(new String[] { "android.permission.READ_EXTERNAL_STORAGE" }, 7);
            return;
        }
        try {
            startActivity(new Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                    Uri.parse("package:" + getPackageName())));
        } catch (Exception e) {
            startActivity(new Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION));
        }
    }

    @Override
    public void onRequestPermissionsResult(int code, String[] perms, int[] results) {
        detect();
    }

    /** Pending pick first (the user may just have come back from granting access), then defaults. */
    private void detect() {
        if (busy) return;
        String pending = getSharedPreferences(PREFS, MODE_PRIVATE).getString(KEY_PENDING, null);
        if (pending != null && tryRoot(new File(pending))) return;
        if (pending != null) return; // keep the message tryRoot wrote for the picked folder
        for (File c : candidates()) {
            if (findDataFiles(c) != null) {
                tryRoot(c);
                return;
            }
        }
        StringBuilder sb = new StringBuilder("No Morrowind data found yet. Looked in:\n");
        for (File c : candidates()) sb.append("  \u2022 ").append(c.getPath()).append('\n');
        setStatus(sb.toString());
    }

    /** Validate and, if good, finish setup on a worker thread. */
    private boolean tryRoot(File root) {
        File df = findDataFiles(root);
        if (df == null) {
            File[] probe = root.listFiles();
            if (probe == null && !haveAllFiles()) {
                setStatus("Can't read " + root.getPath() + " yet.\nTap \"Grant all-files access\", "
                        + "then come back -- or copy the folder to the app's own folder above.");
            } else {
                setStatus(root.getPath() + " doesn't look like Morrowind: no \"Data Files\" "
                        + "folder containing Morrowind.esm.");
            }
            return false;
        }
        final File realRoot = df.equals(root) && root.getParentFile() != null ? root.getParentFile() : root;
        final File dataFiles = df;
        busy = true;
        setStatus("Found Morrowind at " + realRoot.getPath() + "\nUnpacking engine files\u2026");
        new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    extractAssets();
                    writeConfig(dataFiles);
                    getSharedPreferences(PREFS, MODE_PRIVATE).edit()
                            .putString(KEY_ROOT, dataFiles.equals(realRoot) ? realRoot.getAbsolutePath()
                                    : realRoot.getAbsolutePath())
                            .remove(KEY_PENDING)
                            .putLong(KEY_STAMP, stamp(SetupActivity.this))
                            .commit();
                    runOnUiThread(new Runnable() {
                        @Override
                        public void run() {
                            startActivity(new Intent(SetupActivity.this, MainActivity.class));
                            finish();
                        }
                    });
                } catch (Exception e) {
                    busy = false;
                    setStatus("Setup failed: " + e);
                }
            }
        }).start();
        return true;
    }

    @Override
    protected void onActivityResult(int req, int res, Intent data) {
        super.onActivityResult(req, res, data);
        if (req != REQ_TREE || res != RESULT_OK || data == null || data.getData() == null) return;
        Uri tree = data.getData();
        try {
            getContentResolver().takePersistableUriPermission(tree, Intent.FLAG_GRANT_READ_URI_PERMISSION);
        } catch (Exception ignored) {
            // not fatal: the engine reads by path; the grant only helps a later re-pick
        }
        File path = treeToPath(tree);
        if (path == null) {
            setStatus("That folder isn't on device storage the engine can open by path. "
                    + "Pick one on internal storage or an SD card.");
            return;
        }
        getSharedPreferences(PREFS, MODE_PRIVATE).edit().putString(KEY_PENDING, path.getAbsolutePath()).apply();
        tryRoot(path);
    }

    /** "primary:Games/Morrowind" -> /storage/emulated/0/Games/Morrowind; "ABCD-1234:x" -> /storage/ABCD-1234/x. */
    static File treeToPath(Uri tree) {
        if (!"com.android.externalstorage.documents".equals(tree.getAuthority())) return null;
        String id;
        try {
            id = DocumentsContract.getTreeDocumentId(tree);
        } catch (Exception e) {
            return null;
        }
        int colon = id.indexOf(':');
        if (colon < 0) return null;
        String vol = id.substring(0, colon);
        String rel = id.substring(colon + 1);
        File base = "primary".equalsIgnoreCase(vol) ? Environment.getExternalStorageDirectory() : new File("/storage/" + vol);
        return rel.isEmpty() ? base : new File(base, rel);
    }

    private void extractAssets() throws IOException {
        File files = getFilesDir();
        List<String> list = new ArrayList<>();
        try (BufferedReader r = new BufferedReader(new InputStreamReader(getAssets().open("openmw/files.txt"), StandardCharsets.UTF_8))) {
            String line;
            while ((line = r.readLine()) != null) if (!line.trim().isEmpty()) list.add(line.trim());
        }
        deleteTree(new File(files, "resources"));
        deleteTree(new File(files, "mods"));
        byte[] buf = new byte[64 * 1024];
        int n = 0;
        for (String rel : list) {
            File out;
            if (rel.equals("defaults.bin")) out = new File(files, "config/defaults.bin");
            else if (rel.equals("openmw.base.cfg")) continue;
            else out = new File(files, rel);
            out.getParentFile().mkdirs();
            try (InputStream in = getAssets().open("openmw/" + rel); OutputStream o = new FileOutputStream(out)) {
                int k;
                while ((k = in.read(buf)) > 0) o.write(buf, 0, k);
            }
            if (++n % 50 == 0) setStatus("Unpacking engine files\u2026 " + n + "/" + list.size());
        }
    }

    private static void deleteTree(File f) {
        File[] kids = f.listFiles();
        if (kids != null) for (File k : kids) deleteTree(k);
        f.delete();
    }

    private static String q(File f) {
        return "\"" + f.getAbsolutePath() + "\"";
    }

    private void writeConfig(File dataFiles) throws IOException {
        File files = getFilesDir();
        File resources = new File(files, "resources");
        File mod = new File(files, "mods/idle_openmw");
        StringBuilder cfg = new StringBuilder();
        cfg.append("# written by SetupActivity -- clear app data to run setup again\n");
        try (BufferedReader r = new BufferedReader(new InputStreamReader(getAssets().open("openmw/openmw.base.cfg"), StandardCharsets.UTF_8))) {
            String line;
            while ((line = r.readLine()) != null) {
                String t = line.trim();
                if (t.startsWith("resources=")) line = "resources=" + q(resources);
                else if (t.startsWith("data=") && t.contains("vfs-mw")) line = "data=" + q(new File(resources, "vfs-mw"));
                else if (t.startsWith("data=") || t.startsWith("content=") || t.startsWith("fallback-archive=")) continue;
                cfg.append(line).append('\n');
            }
        }
        cfg.append("\n# Morrowind\n");
        cfg.append("data=").append(q(dataFiles)).append('\n');
        for (String bsa : new String[] { "Morrowind.bsa", "Tribunal.bsa", "Bloodmoon.bsa" }) {
            File f = child(dataFiles, bsa);
            if (f != null) cfg.append("fallback-archive=").append(f.getName()).append('\n');
        }
        for (String esm : new String[] { "Morrowind.esm", "Tribunal.esm", "Bloodmoon.esm" }) {
            File f = child(dataFiles, esm);
            if (f != null) cfg.append("content=").append(f.getName()).append('\n');
        }
        if (new File(mod, "idle_openmw.omwscripts").isFile()) {
            cfg.append("\n# idle_openmw\n");
            cfg.append("data=").append(q(mod)).append('\n');
            cfg.append("content=idle_openmw.omwscripts\n");
        }
        File dir = new File(files, "config");
        dir.mkdirs();
        try (Writer w = new OutputStreamWriter(new FileOutputStream(new File(dir, "openmw.cfg")), StandardCharsets.UTF_8)) {
            w.write(cfg.toString());
        }
    }
}