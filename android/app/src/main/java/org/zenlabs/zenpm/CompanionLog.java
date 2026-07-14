package org.zenlabs.zenpm;

import android.content.Context;

import java.io.File;
import java.io.FileWriter;
import java.io.IOException;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import java.util.TimeZone;

final class CompanionLog {
    private CompanionLog() {}

    static synchronized void write(Context context, String home, String message) {
        String line = timestamp() + "  " + message + "\n";
        if (home != null && !home.isEmpty() && write(new File(home, "android-companion.log"), line)) return;
        File fallback = context.getExternalFilesDir(null);
        if (fallback != null) write(new File(fallback, "android-companion.log"), line);
    }

    static synchronized void writeUpdateStatus(Context context, String home, String state, String detail) {
        String value = state + "\n" + (detail == null ? "" : detail.replace('\n', ' ')) + "\n";
        if (home != null && !home.isEmpty() && write(new File(home, "android-companion-update.status"), value)) return;
        File fallback = context.getExternalFilesDir(null);
        if (fallback != null) write(new File(fallback, "android-companion-update.status"), value);
    }

    private static String timestamp() {
        SimpleDateFormat format = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US);
        format.setTimeZone(TimeZone.getTimeZone("UTC"));
        return format.format(new Date());
    }

    private static boolean write(File file, String line) {
        File dir = file.getParentFile();
        if (dir == null || (!dir.exists() && !dir.mkdirs())) return false;
        try {
            FileWriter writer = new FileWriter(file, true);
            writer.write(line);
            writer.close();
            return true;
        } catch (IOException ignored) {
            return false;
        }
    }
}
