package org.zenlabs.zenpm;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.provider.Settings;

public final class ZenPMActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        Uri data = getIntent().getData();
        Intent service = new Intent(this, ZenPMService.class);
        if (data != null && "update".equals(data.getHost())) {
            String logHome = data.getQueryParameter("home");
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                && !getPackageManager().canRequestPackageInstalls()) {
                String message = "Allow ZenPM Backend to install unknown apps, then request the update again.";
                CompanionLog.write(this, logHome, message);
                CompanionLog.writeUpdateStatus(this, logHome, "failed", message);
                Intent settings = new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:" + getPackageName()));
                startActivity(settings);
                finish();
                return;
            }
            CompanionLog.write(this, logHome, "Received companion update request.");
            ZenPMUpdater.start(this, logHome);
        } else if (data != null && "start".equals(data.getHost())) {
            String logHome = data.getQueryParameter("home");
            String root = data.getQueryParameter("root");
            service.putExtra("zenpm_log_home", logHome);
            service.putExtra("koreader_root", root);
            CompanionLog.writeVersion(this, logHome);
            CompanionLog.write(this, logHome, "Received KOReader start request. KOReader root=" + root);
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && !Environment.isExternalStorageManager()) {
                CompanionLog.write(this, logHome, "All files access is required; opening Android settings.");
                Intent settings = new Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                    Uri.parse("package:" + getPackageName()));
                startActivity(settings);
                finish();
                return;
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(service);
            } else {
                startService(service);
            }
        }
        finish();
    }
}
