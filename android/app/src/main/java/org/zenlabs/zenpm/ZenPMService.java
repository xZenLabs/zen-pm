package org.zenlabs.zenpm;

import android.app.Service;
import android.content.Intent;
import android.os.IBinder;

public final class ZenPMService extends Service {
    private static boolean nativeLoaded;
    private static String nativeLoadError;
    static {
        try {
            System.loadLibrary("zenpm");
            nativeLoaded = true;
        } catch (UnsatisfiedLinkError error) {
            nativeLoadError = error.toString();
        }
    }
    private static boolean started;
    private static native void nativeStart(String home, String koreaderRoot, int port);

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        synchronized (ZenPMService.class) {
            String home = intent == null ? null : intent.getStringExtra("zenpm_home");
            if (!nativeLoaded) {
                CompanionLog.write(home, "Could not load libzenpm.so: " + nativeLoadError);
            } else if (!started && home != null && !home.isEmpty()) {
                String root = intent.getStringExtra("koreader_root");
                CompanionLog.write(home, "Starting native backend.");
                nativeStart(home, root == null ? "" : root, 8080);
                started = true;
            } else if (home != null && !home.isEmpty()) {
                CompanionLog.write(home, "Native backend is already running.");
            }
        }
        return START_NOT_STICKY;
    }

    @Override public IBinder onBind(Intent intent) { return null; }
}
