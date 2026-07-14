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
            String home = intent == null ? null : intent.getStringExtra("zenpm_home");
            if (!started && home != null && !home.isEmpty()) {
                String root = intent.getStringExtra("koreader_root");
                nativeStart(home, root == null ? "" : root, 8080);
                started = true;
            }
        }
        return START_NOT_STICKY;
    }

    @Override public IBinder onBind(Intent intent) { return null; }
}
