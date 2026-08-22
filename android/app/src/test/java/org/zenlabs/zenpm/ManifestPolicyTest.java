package org.zenlabs.zenpm;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import javax.xml.parsers.DocumentBuilderFactory;
import org.junit.Test;
import org.w3c.dom.Document;
import org.w3c.dom.Element;
import org.w3c.dom.NodeList;

public final class ManifestPolicyTest {
    @Test public void launcherUsesZenPMIconAndDedicatedMainIntent() throws Exception {
        Path manifestPath = source("src/main/AndroidManifest.xml");
        String manifest = new String(Files.readAllBytes(manifestPath), StandardCharsets.UTF_8);
        assertTrue(manifest.contains("android:icon=\"@drawable/zenpm_icon\""));
        assertTrue(manifest.contains("android:roundIcon=\"@drawable/zenpm_icon\""));
        assertTrue(Files.size(source("src/main/res/drawable-nodpi/zenpm_icon.png")) > 0);
        assertTrue(Files.size(source("src/main/res/drawable-night-nodpi/zenpm_icon.png")) > 0);

        Document document = DocumentBuilderFactory.newInstance().newDocumentBuilder()
            .parse(manifestPath.toFile());
        Element activity = component(document, "activity", ".ZenPMActivity");
        assertNotNull(activity);
        assertFalse(hasNamedChild(activity, "action", "android.intent.action.MAIN"));

        Element launcher = component(document, "activity-alias", ".ZenPMLauncher");
        assertNotNull(launcher);
        assertEquals("true", launcher.getAttribute("android:exported"));
        assertEquals(".ZenPMActivity", launcher.getAttribute("android:targetActivity"));
        assertTrue(hasNamedChild(launcher, "action", "android.intent.action.MAIN"));
        assertTrue(hasNamedChild(launcher, "category", "android.intent.category.LAUNCHER"));

        String activitySource = new String(Files.readAllBytes(source(
            "src/main/java/org/zenlabs/zenpm/ZenPMActivity.java")), StandardCharsets.UTF_8);
        assertTrue(activitySource.contains("Intent.ACTION_MAIN.equals(incoming.getAction())"));
        assertTrue(activitySource.contains("Settings.ACTION_APPLICATION_DETAILS_SETTINGS"));
    }

    @Test public void allFilesAccessIsRequestedFromStartAndLauncherWithFallbacks() throws Exception {
        String activitySource = new String(Files.readAllBytes(source(
            "src/main/java/org/zenlabs/zenpm/ZenPMActivity.java")), StandardCharsets.UTF_8);

        assertEquals(3, occurrences(activitySource, "openAllFilesAccessSettings()"));
        assertTrue(activitySource.contains("Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION"));
        assertTrue(activitySource.contains("Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION"));
        assertTrue(activitySource.contains("ActivityNotFoundException | SecurityException"));
    }

    private static Path source(String relative) {
        Path fromRoot = Paths.get("app").resolve(relative);
        return Files.exists(fromRoot) ? fromRoot : Paths.get(relative);
    }

    private static Element component(Document document, String tag, String name) {
        NodeList nodes = document.getElementsByTagName(tag);
        for (int index = 0; index < nodes.getLength(); index++) {
            Element element = (Element) nodes.item(index);
            if (name.equals(element.getAttribute("android:name"))) return element;
        }
        return null;
    }

    private static boolean hasNamedChild(Element parent, String tag, String name) {
        NodeList nodes = parent.getElementsByTagName(tag);
        for (int index = 0; index < nodes.getLength(); index++) {
            if (name.equals(((Element) nodes.item(index)).getAttribute("android:name"))) return true;
        }
        return false;
    }

    private static int occurrences(String value, String search) {
        int count = 0;
        int offset = 0;
        while ((offset = value.indexOf(search, offset)) >= 0) {
            count++;
            offset += search.length();
        }
        return count;
    }
}
