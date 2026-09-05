package org.zenlabs.zenpm;

import android.content.Context;
import android.content.pm.PackageManager;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import java.util.TimeZone;

final class CompanionLog {
    static final int MAX_BYTES = 1024 * 1024;
    private CompanionLog() {}

    static synchronized void write(Context context, String home, String message) {
        String line = timestamp() + "  " + message + "\n";
        if (home != null && !home.isEmpty() && write(new File(home, "android-companion.log"), line)) return;
        File fallback = context.getExternalFilesDir(null);
        if (fallback != null) write(new File(fallback, "android-companion.log"), line);
    }

    static synchronized void writeUpdateStatus(Context context, String home, String state, String detail) {
        String value = state + "\n" + (detail == null ? "" : detail.replace('\n', ' ')) + "\n";
        if (home != null && !home.isEmpty() && overwrite(new File(home, "android-companion-update.status"), value)) return;
        File fallback = context.getExternalFilesDir(null);
        if (fallback != null) overwrite(new File(fallback, "android-companion-update.status"), value);
    }

    static synchronized void writeVersion(Context context, String home) {
        try {
            String version = context.getPackageManager()
                .getPackageInfo(context.getPackageName(), 0).versionName + "\n";
            if (home != null && !home.isEmpty() && overwrite(new File(home, "android-companion.version"), version)) return;
            File fallback = context.getExternalFilesDir(null);
            if (fallback != null) overwrite(new File(fallback, "android-companion.version"), version);
        } catch (PackageManager.NameNotFoundException ignored) {}
    }

    private static String timestamp() {
        SimpleDateFormat format = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US);
        format.setTimeZone(TimeZone.getTimeZone("UTC"));
        return format.format(new Date());
    }

    private static boolean write(File file, String line) {
        return write(file, line, true);
    }

    private static boolean overwrite(File file, String line) {
        return write(file, line, false);
    }

    static synchronized boolean write(File file, String line, boolean append) {
        File dir = file.getParentFile();
        if (dir == null || (!dir.exists() && !dir.mkdirs())) return false;
        try {
            byte[] data = line.getBytes(StandardCharsets.UTF_8);
            if (append && data.length > MAX_BYTES / 2) {
                data = Arrays.copyOfRange(data, data.length - MAX_BYTES / 2, data.length);
            }
            if (append && file.length() + data.length > MAX_BYTES) {
                // Keep the inode: the native backend also appends to this file.
                try (RandomAccessFile log = new RandomAccessFile(file, "rw")) {
                    byte[] tail = new byte[(int) Math.min(log.length(), MAX_BYTES / 2)];
                    log.seek(log.length() - tail.length);
                    log.readFully(tail);
                    int start = 0;
                    while (start < tail.length && tail[start] != '\n') start++;
                    start = start < tail.length ? start + 1 : 0;
                    log.seek(0);
                    log.write(tail, start, tail.length - start);
                    log.setLength(tail.length - start);
                }
            }
            try (FileOutputStream writer = new FileOutputStream(file, append)) {
                writer.write(data);
            }
            return true;
        } catch (IOException ignored) {
            return false;
        }
    }
}
