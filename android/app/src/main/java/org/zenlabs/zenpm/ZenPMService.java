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
    private static native void nativeStart(String home, String logHome, String koreaderRoot, int port);

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        synchronized (ZenPMService.class) {
            String logHome = intent == null ? null : intent.getStringExtra("zenpm_log_home");
            if (!nativeLoaded) {
                CompanionLog.write(this, logHome, "Could not load libzenpm.so: " + nativeLoadError);
            } else if (!started) {
                String root = intent.getStringExtra("koreader_root");
                String home = getFilesDir().getAbsolutePath();
                CompanionLog.write(this, logHome, "Starting native backend.");
                nativeStart(home, logHome, root == null ? "" : root, 8080);
                started = true;
            } else {
                CompanionLog.write(this, logHome, "Native backend is already running.");
            }
        }
        return START_NOT_STICKY;
    }

    @Override public IBinder onBind(Intent intent) { return null; }

    @Override public void onDestroy() {
        super.onDestroy();
        CompanionLog.write(this, null, "Stopping native backend process.");
        android.os.Process.killProcess(android.os.Process.myPid());
    }
}
