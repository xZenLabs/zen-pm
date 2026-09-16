package org.zenlabs.zenpm;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public final class ZenPMUpdaterTest {
    @Test public void prereleasesRequireBetaChannel() {
        assertFalse(ZenPMUpdater.releaseAllowed(false, true, false));
        assertTrue(ZenPMUpdater.releaseAllowed(false, true, true));
        assertFalse(ZenPMUpdater.releaseAllowed(true, false, true));
    }

    @Test public void compareLongUntrustedVersionWithoutBacktracking() {
        StringBuilder version = new StringBuilder("v1.2.3-");
        for (int i = 0; i < 10000; i++) version.append('a');
        assertEquals(-1, ZenPMUpdater.compareVersions(version.toString(), "1.2.3"));
        assertEquals(1, ZenPMUpdater.compareVersions("v1.2.3", version.toString()));
    }
}
