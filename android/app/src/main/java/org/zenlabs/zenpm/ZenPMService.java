package org.zenlabs.zenpm;

import android.app.Service;
import android.content.Intent;
import android.os.IBinder;

public final class ZenPMService extends Service {
    static { System.loadLibrary("zenpm"); }
    private static boolean started;
    private static native void nativeStart(String home, String koreaderRoot, int port);

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        synchronized (ZenPMService.class) {
            if (!started) {
                String home = intent.getStringExtra("zenpm_home");
                String root = intent.getStringExtra("koreader_root");
                nativeStart(home == null ? "" : home, root == null ? "" : root, 8080);
                started = true;
            }
        }
        return START_STICKY;
    }

    @Override public IBinder onBind(Intent intent) { return null; }
}
