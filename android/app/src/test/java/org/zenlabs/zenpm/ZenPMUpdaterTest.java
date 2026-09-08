package org.zenlabs.zenpm;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public final class ZenPMUpdaterTest {
    @Test public void prereleasesRequireBetaChannel() {
        assertFalse(ZenPMUpdater.releaseAllowed(false, true, false));
        assertTrue(ZenPMUpdater.releaseAllowed(false, true, true));
        assertFalse(ZenPMUpdater.releaseAllowed(true, false, true));
    }
}
