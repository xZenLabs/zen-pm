package org.zenlabs.zenpm;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Arrays;
import org.junit.Test;

public final class CompanionLogTest {
    @Test public void logsAreBoundedAndStatusIsReplaced() throws Exception {
        File dir = Files.createTempDirectory("zenpm-log-test").toFile();
        File log = new File(dir, "android-companion.log");
        File status = new File(dir, "android-companion-update.status");
        try {
            char[] huge = new char[CompanionLog.MAX_BYTES * 2];
            Arrays.fill(huge, 'x');
            Files.write(log.toPath(), (new String(huge) + "\nrecent\n").getBytes(StandardCharsets.UTF_8));
            assertTrue(CompanionLog.write(log, "new message\n", true));
            assertTrue(log.length() <= CompanionLog.MAX_BYTES);
            assertTrue(new String(Files.readAllBytes(log.toPath()), StandardCharsets.UTF_8).endsWith("recent\nnew message\n"));
            for (int i = 0; i < 4; i++) {
                assertTrue(CompanionLog.write(log, new String(huge), true));
                assertTrue(log.length() <= CompanionLog.MAX_BYTES);
            }
            CompanionLog.writeUpdateStatus(null, dir.getPath(), "checking", null);
            CompanionLog.writeUpdateStatus(null, dir.getPath(), "installer_opened", "ready");
            assertEquals("installer_opened\nready\n", new String(Files.readAllBytes(status.toPath()), StandardCharsets.UTF_8));
        } finally {
            Files.deleteIfExists(log.toPath());
            Files.deleteIfExists(status.toPath());
            Files.delete(dir.toPath());
        }
    }
}
