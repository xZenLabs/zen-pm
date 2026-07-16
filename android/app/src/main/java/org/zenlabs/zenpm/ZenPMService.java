package org.zenlabs.zenpm;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.os.Build;
import android.os.IBinder;
import android.os.Process;
import java.util.Arrays;

public final class ZenPMService extends Service {
    private static final String CHANNEL_ID = "zenpm_backend";
    private static final int NOTIFICATION_ID = 1;
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
    private static native void nativeStart(String home, String logHome, String koreaderRoot, int port);

    private static String abiInfo() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            String process = Build.VERSION.SDK_INT >= Build.VERSION_CODES.M
                ? Boolean.toString(Process.is64Bit()) : "unknown";
            return "supported_abis=" + Arrays.toString(Build.SUPPORTED_ABIS)
                + " process_64_bit=" + process;
        }
        return "cpu_abi=" + Build.CPU_ABI;
    }

    @Override public void onCreate() {
        super.onCreate();
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                CHANNEL_ID, "ZenPM Backend", NotificationManager.IMPORTANCE_LOW);
            NotificationManager manager = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
            manager.createNotificationChannel(channel);
        }
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        synchronized (ZenPMService.class) {
            String logHome = intent == null ? null : intent.getStringExtra("zenpm_log_home");
            Notification.Builder notification = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                ? new Notification.Builder(this, CHANNEL_ID)
                : new Notification.Builder(this);
            startForeground(NOTIFICATION_ID, notification
                .setContentTitle("ZenPM Backend")
                .setContentText("Serving ZenPM requests")
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setOngoing(true)
                .build());
            if (!nativeLoaded) {
                CompanionLog.write(this, logHome, "Could not load libzenpm.so: " + nativeLoadError);
            } else {
                String root = intent == null ? "" : intent.getStringExtra("koreader_root");
                String home = getFilesDir().getAbsolutePath();
                CompanionLog.write(this, logHome, "Ensuring native backend is running. " + abiInfo());
                nativeStart(home, logHome, root == null ? "" : root, 8080);
            }
        }
        return START_NOT_STICKY;
    }

    @Override public IBinder onBind(Intent intent) { return null; }
}
