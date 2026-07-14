package org.zenlabs.zenpm;

import java.io.File;
import java.io.FileWriter;
import java.io.IOException;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import java.util.TimeZone;

final class CompanionLog {
    private CompanionLog() {}

    static synchronized void write(String home, String message) {
        if (home == null || home.isEmpty()) return;
        File dir = new File(home);
        if (!dir.exists() && !dir.mkdirs()) return;
        try {
            SimpleDateFormat format = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US);
            format.setTimeZone(TimeZone.getTimeZone("UTC"));
            FileWriter writer = new FileWriter(new File(dir, "android-companion.log"), true);
            writer.write(format.format(new Date()) + "  " + message + "\n");
            writer.close();
        } catch (IOException ignored) {
        }
    }
}
