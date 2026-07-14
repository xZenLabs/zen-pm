package org.zenlabs.zenpm;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;

public final class ZenPMActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        Uri data = getIntent().getData();
        Intent service = new Intent(this, ZenPMService.class);
        if (data != null && "start".equals(data.getHost())) {
            String home = data.getQueryParameter("home");
            service.putExtra("zenpm_home", home);
            service.putExtra("koreader_root", data.getQueryParameter("root"));
            CompanionLog.write(home, "Received KOReader start request.");
            startService(service);
        }
        finish();
    }
}
