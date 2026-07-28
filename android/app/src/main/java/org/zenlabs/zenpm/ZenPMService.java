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
    private static final int LOOPBACK_PORT = 18765;
    static final String ACTION_STOP = "org.zenlabs.zenpm.action.STOP";
    private static boolean nativeLoaded;
    private static String nativeLoadError;
    private Thread backendThread;
    private BackendConfig pendingStart;
    private boolean stopping;
    private int latestStartId;
    static {
        try {
            System.loadLibrary("zenpm");
            nativeLoaded = true;
        } catch (UnsatisfiedLinkError error) {
            nativeLoadError = error.toString();
        }
    }
    private static native void nativeRun(String home, String logHome, String koreaderRoot, int port);
    private static native void nativeStop();

    private static final class BackendConfig {
        final String home;
        final String logHome;
        final String koreaderRoot;

        BackendConfig(String home, String logHome, String koreaderRoot) {
            this.home = home;
            this.logHome = logHome;
            this.koreaderRoot = koreaderRoot;
        }
    }

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
        String logHome = intent == null ? null : intent.getStringExtra("zenpm_log_home");
        synchronized (this) {
            latestStartId = startId;
            if (ACTION_STOP.equals(intent == null ? null : intent.getAction())) {
                stopping = true;
                if (nativeLoaded) nativeStop();
                return START_NOT_STICKY;
            }

            startForegroundNotification();
            if (!nativeLoaded) {
                CompanionLog.write(this, logHome, "Could not load libzenpm.so: " + nativeLoadError);
                stopForeground(true);
                stopSelfResult(startId);
                return START_NOT_STICKY;
            }

            String root = intent == null ? "" : intent.getStringExtra("koreader_root");
            BackendConfig config = new BackendConfig(
                getFilesDir().getAbsolutePath(), logHome, root == null ? "" : root);
            if (backendThread == null || !backendThread.isAlive()) {
                stopping = false;
                startBackend(config);
            } else if (stopping) {
                // A new request arrived while the old listener was closing.
                // The worker starts this configuration as soon as it exits.
                pendingStart = config;
            }
        }
        return START_NOT_STICKY;
    }

    private void startForegroundNotification() {
        Notification.Builder notification = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
            ? new Notification.Builder(this, CHANNEL_ID)
            : new Notification.Builder(this);
        startForeground(NOTIFICATION_ID, notification
            .setContentTitle("ZenPM Backend")
            .setContentText("Serving ZenPM requests")
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .build());
    }

    private void startBackend(final BackendConfig initial) {
        backendThread = new Thread(new Runnable() {
            @Override public void run() {
                BackendConfig config = initial;
                while (true) {
                    CompanionLog.write(ZenPMService.this, config.logHome,
                        "Starting native backend. " + abiInfo());
                    nativeRun(config.home, config.logHome, config.koreaderRoot, LOOPBACK_PORT);

                    synchronized (ZenPMService.this) {
                        if (pendingStart != null) {
                            config = pendingStart;
                            pendingStart = null;
                            stopping = false;
                            continue;
                        }
                        backendThread = null;
                        stopping = false;
                        stopForeground(true);
                        stopSelfResult(latestStartId);
                        return;
                    }
                }
            }
        }, "ZenPMBackend");
        backendThread.start();
    }

    @Override public void onDestroy() {
        if (nativeLoaded) nativeStop();
        super.onDestroy();
    }

    @Override public IBinder onBind(Intent intent) { return null; }
}
