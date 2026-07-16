package org.zenlabs.zenpm;

import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.security.MessageDigest;

final class ZenPMUpdater {
    private static final String RELEASES_URL = "https://api.github.com/repos/xZenLabs/zen-pm/releases?per_page=100";
    private static final String APK_MIME = "application/vnd.android.package-archive";

    private ZenPMUpdater() {}

    static void start(final Context context, final String logHome) {
        CompanionLog.writeUpdateStatus(context, logHome, "checking", null);
        new Thread(new Runnable() {
            @Override public void run() {
                try {
                    Release release = latestRelease();
                    if (compareVersions(release.version, installedVersion(context)) <= 0) {
                        CompanionLog.write(context, logHome, "ZenPM companion is up to date.");
                        CompanionLog.writeUpdateStatus(context, logHome, "up_to_date", null);
                        return;
                    }
                    File apk = new File(context.getCacheDir(), "zenpm-update.apk");
                    CompanionLog.write(context, logHome, "Downloading ZenPM companion " + release.version + ".");
                    CompanionLog.writeUpdateStatus(context, logHome, "downloading", null);
                    download(release, apk);
                    validateApk(context, apk);
                    requestInstall(context, logHome, apk);
                } catch (Exception error) {
                    CompanionLog.write(context, logHome, "Companion update failed: " + error.getMessage());
                    CompanionLog.writeUpdateStatus(context, logHome, "failed", error.getMessage());
                }
            }
        }, "ZenPMUpdater").start();
    }

    private static Release latestRelease() throws Exception {
        HttpURLConnection connection = (HttpURLConnection) new URL(RELEASES_URL).openConnection();
        connection.setRequestProperty("User-Agent", "ZenPM-Companion");
        connection.setConnectTimeout(15000);
        connection.setReadTimeout(30000);
        if (connection.getResponseCode() != HttpURLConnection.HTTP_OK) {
            throw new IOException("GitHub returned HTTP " + connection.getResponseCode());
        }
        JSONArray releases = new JSONArray(readAll(connection.getInputStream()));
        for (int i = 0; i < releases.length(); i++) {
            JSONObject release = releases.getJSONObject(i);
            if (release.optBoolean("draft") || release.optBoolean("prerelease")) continue;
            String version = release.optString("tag_name").replaceFirst("^v", "");
            String assetName = "ZenPM-android-" + version + ".apk";
            JSONArray assets = release.optJSONArray("assets");
            if (assets == null) continue;
            for (int j = 0; j < assets.length(); j++) {
                JSONObject asset = assets.getJSONObject(j);
                String url = asset.optString("browser_download_url");
                String digest = asset.optString("digest");
                if (assetName.equals(asset.optString("name")) && validDigest(digest) && trustedReleaseURL(url)) {
                    return new Release(version, url, digest.substring("sha256:".length()));
                }
            }
        }
        throw new IOException("No compatible companion update was found.");
    }

    private static void download(Release release, File destination) throws Exception {
        URL url = new URL(release.url);
        HttpURLConnection connection = null;
        for (int redirects = 0; redirects < 6; redirects++) {
            if (!trustedDownloadURL(url)) throw new IOException("Update download URL is not trusted.");
            connection = (HttpURLConnection) url.openConnection();
            connection.setInstanceFollowRedirects(false);
            connection.setRequestProperty("User-Agent", "ZenPM-Companion");
            connection.setConnectTimeout(15000);
            connection.setReadTimeout(30000);
            int status = connection.getResponseCode();
            if (status >= 300 && status < 400) {
                String location = connection.getHeaderField("Location");
                if (location == null) throw new IOException("Update redirect had no location.");
                url = new URL(url, location);
                continue;
            }
            if (status != HttpURLConnection.HTTP_OK) throw new IOException("Update download returned HTTP " + status);
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            InputStream input = new BufferedInputStream(connection.getInputStream());
            FileOutputStream output = new FileOutputStream(destination);
            try {
                byte[] buffer = new byte[64 * 1024];
                int count;
                while ((count = input.read(buffer)) != -1) {
                    digest.update(buffer, 0, count);
                    output.write(buffer, 0, count);
                }
            } finally {
                input.close();
                output.close();
            }
            if (!hex(digest.digest()).equalsIgnoreCase(release.sha256)) {
                destination.delete();
                throw new IOException("Downloaded update checksum did not match.");
            }
            return;
        }
        throw new IOException("Update download redirected too many times.");
    }

    private static void validateApk(Context context, File apk) throws IOException {
        PackageManager packages = context.getPackageManager();
        PackageInfo archive = packages.getPackageArchiveInfo(apk.getPath(), 0);
        if (archive == null || !context.getPackageName().equals(archive.packageName)) {
            throw new IOException("Downloaded file is not a ZenPM companion APK.");
        }
    }

    private static void requestInstall(Context context, String logHome, File apk) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !context.getPackageManager().canRequestPackageInstalls()) {
            String message = "Allow ZenPM Backend to install unknown apps, then request the update again.";
            CompanionLog.write(context, logHome, message);
            CompanionLog.writeUpdateStatus(context, logHome, "failed", message);
            Intent settings = new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:" + context.getPackageName()));
            settings.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            context.startActivity(settings);
            return;
        }
        Uri uri = Uri.parse("content://" + context.getPackageName() + ".updates/update.apk");
        Intent install = new Intent(Intent.ACTION_VIEW);
        install.setDataAndType(uri, APK_MIME);
        install.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_ACTIVITY_NEW_TASK);
        CompanionLog.write(context, logHome, "Opening Android package installer for ZenPM companion update.");
        context.startActivity(install);
        CompanionLog.writeUpdateStatus(context, logHome, "installer_opened", null);
    }

    private static String installedVersion(Context context) throws PackageManager.NameNotFoundException {
        return context.getPackageManager().getPackageInfo(context.getPackageName(), 0).versionName;
    }

    private static boolean trustedReleaseURL(String value) {
        try {
            URL url = new URL(value);
            return "https".equals(url.getProtocol()) && "github.com".equalsIgnoreCase(url.getHost())
                && url.getPath().startsWith("/xZenLabs/zen-pm/releases/download/");
        } catch (Exception error) {
            return false;
        }
    }

    private static boolean trustedDownloadURL(URL url) {
        if (!"https".equals(url.getProtocol())) return false;
        String host = url.getHost().toLowerCase();
        return "github.com".equals(host)
            || "objects.githubusercontent.com".equals(host)
            || "release-assets.githubusercontent.com".equals(host)
            || "github-releases.githubusercontent.com".equals(host);
    }

    private static boolean validDigest(String digest) {
        return digest != null && digest.matches("sha256:[0-9a-fA-F]{64}");
    }

    private static String readAll(InputStream input) throws IOException {
        try {
            ByteArrayOutputStream output = new ByteArrayOutputStream();
            byte[] buffer = new byte[8192];
            int count;
            while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
            return output.toString("UTF-8");
        } finally {
            input.close();
        }
    }

    private static String hex(byte[] bytes) {
        StringBuilder result = new StringBuilder(bytes.length * 2);
        for (byte value : bytes) result.append(String.format("%02x", value & 0xff));
        return result.toString();
    }

    private static int compareVersions(String left, String right) {
        String leftValue = left.replaceFirst("^v", "");
        String rightValue = right.replaceFirst("^v", "");
        String[] leftParts = leftValue.split("[-+]", 2)[0].split("\\.");
        String[] rightParts = rightValue.split("[-+]", 2)[0].split("\\.");
        for (int i = 0; i < 3; i++) {
            int a = i < leftParts.length ? Integer.parseInt(leftParts[i]) : 0;
            int b = i < rightParts.length ? Integer.parseInt(rightParts[i]) : 0;
            if (a != b) return a < b ? -1 : 1;
        }
        boolean leftPrerelease = leftValue.matches(".*[-+].+");
        boolean rightPrerelease = rightValue.matches(".*[-+].+");
        if (leftPrerelease != rightPrerelease) return leftPrerelease ? -1 : 1;
        if (!leftPrerelease) return 0;
        return Integer.compare(prereleaseNumber(leftValue), prereleaseNumber(rightValue));
    }

    private static int prereleaseNumber(String value) {
        java.util.regex.Matcher matcher = java.util.regex.Pattern.compile("(\\d+)$").matcher(value);
        return matcher.find() ? Integer.parseInt(matcher.group(1)) : 0;
    }

    private static final class Release {
        final String version;
        final String url;
        final String sha256;

        Release(String version, String url, String sha256) {
            this.version = version;
            this.url = url;
            this.sha256 = sha256;
        }
    }
}
