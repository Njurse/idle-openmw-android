package is.xyz.idle_openmw;

import android.app.Activity;
import android.app.ActivityManager;
import android.app.ApplicationExitInfo;
import android.os.Build;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.FileReader;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;
import java.util.List;

/**
 * Feeds the shell's on-screen log strip (AppUi.Shell#log).
 *
 *  - replays the tail of the PREVIOUS run (files/ui-log.txt) and its exit reason, so a native crash
 *    that killed the process is readable on the next launch;
 *  - tails this process's own logcat (tags idle-openmw, SDL, OpenMW + every warning/error), which
 *    is how the native dlopen/dlsym guard lines reach the screen without any JNI;
 *  - persists every line to files/ui-log.txt.
 * Every step is best-effort: a failure here must never take the app down.
 */
final class LogStrip {

    private static Writer sOut;
    private static AppUi.Shell sShell;

    private LogStrip() {}

    static synchronized void line(String text) {
        if (text == null) return;
        if (sShell != null) sShell.log(text);
        if (sOut != null) {
            try {
                sOut.write(text);
                sOut.write('\n');
                sOut.flush();
            } catch (Throwable ignored) {
            }
        }
    }

    static void start(Activity activity, AppUi.Shell shell) {
        File file = new File(activity.getFilesDir(), "ui-log.txt");
        replayPrevious(activity, shell, file);
        synchronized (LogStrip.class) {
            sShell = shell;
            try {
                sOut = new OutputStreamWriter(new FileOutputStream(file, false), StandardCharsets.UTF_8);
            } catch (Throwable ignored) {
            }
        }
        tailLogcat();
    }

    private static void replayPrevious(Activity activity, AppUi.Shell shell, File file) {
        try {
            if (file.isFile()) {
                ArrayDeque<String> tail = new ArrayDeque<>();
                try (BufferedReader r = new BufferedReader(new FileReader(file))) {
                    for (String l; (l = r.readLine()) != null; ) {
                        tail.addLast(l);
                        if (tail.size() > 4) tail.removeFirst();
                    }
                }
                for (String l : tail) shell.log("prev| " + l);
            }
        } catch (Throwable ignored) {
        }
        try {
            if (Build.VERSION.SDK_INT >= 30) {
                ActivityManager am = (ActivityManager) activity.getSystemService(Activity.ACTIVITY_SERVICE);
                List<ApplicationExitInfo> exits =
                        am.getHistoricalProcessExitReasons(activity.getPackageName(), 0, 1);
                if (exits != null && !exits.isEmpty()) {
                    ApplicationExitInfo e = exits.get(0);
                    shell.log("prev exit: " + exitName(e.getReason()) + " sig/status=" + e.getStatus()
                            + (e.getDescription() != null ? " " + e.getDescription() : ""));
                    if (e.getReason() == ApplicationExitInfo.REASON_CRASH_NATIVE) nativeFrames(e, shell);
                }
            }
        } catch (Throwable ignored) {
        }
    }

    /** Best-effort: tombstone trace (API 31+, protobuf) -> printable strings that look like frames. */
    private static void nativeFrames(ApplicationExitInfo e, AppUi.Shell shell) {
        try (java.io.InputStream in = e.getTraceInputStream()) {
            if (in == null) { shell.log("prev bt: (no tombstone trace)"); return; }
            byte[] buf = new byte[1 << 20];
            int n = 0;
            for (int k; n < buf.length && (k = in.read(buf, n, buf.length - n)) > 0; ) n += k;
            StringBuilder cur = new StringBuilder();
            int shown = 0;
            String last = "";
            for (int i = 0; i <= n && shown < 12; i++) {
                int c = i < n ? (buf[i] & 0xff) : 0;
                if (c >= 0x20 && c < 0x7f) { cur.append((char) c); continue; }
                String w = cur.toString();
                cur.setLength(0);
                if (w.length() < 4 || w.equals(last)) continue;
                if (w.contains("SIG") || w.contains("signal") || w.contains("fault")
                        || w.endsWith(".so") || w.contains("::") || w.startsWith("_Z")) {
                    shell.log("prev bt| " + (w.length() > 120 ? w.substring(0, 120) : w));
                    last = w;
                    shown++;
                }
            }
            if (shown == 0) shell.log("prev bt: trace had no readable frames");
        } catch (Throwable t) {
            shell.log("prev bt unavailable: " + t);
        }
    }

    private static String exitName(int reason) {
        switch (reason) {
            case ApplicationExitInfo.REASON_CRASH_NATIVE: return "NATIVE CRASH";
            case ApplicationExitInfo.REASON_CRASH: return "JAVA CRASH";
            case ApplicationExitInfo.REASON_ANR: return "ANR";
            case ApplicationExitInfo.REASON_EXIT_SELF: return "exit()";
            case ApplicationExitInfo.REASON_SIGNALED: return "signaled";
            case ApplicationExitInfo.REASON_LOW_MEMORY: return "low memory";
            case ApplicationExitInfo.REASON_USER_REQUESTED: return "user/force-stop";
            default: return "reason " + reason;
        }
    }

    private static void tailLogcat() {
        Thread t = new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    String pid = String.valueOf(android.os.Process.myPid());
                    Process p = Runtime.getRuntime().exec(new String[] {
                            "logcat", "-v", "tag", "-T", "50", "--pid=" + pid,
                            "idle-openmw:V", "SDL:V", "OpenMW:V", "openmw:V", "*:W" });
                    BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
                    for (String l; (l = r.readLine()) != null; ) {
                        if (l.startsWith("---------")) continue;
                        line(l);
                    }
                } catch (Throwable e) {
                    line("log tail unavailable: " + e);
                }
            }
        }, "idle-openmw-logtail");
        t.setDaemon(true);
        t.start();
    }
}
