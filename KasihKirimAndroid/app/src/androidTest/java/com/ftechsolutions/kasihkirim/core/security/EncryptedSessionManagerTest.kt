package com.ftechsolutions.kasihkirim.core.security

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import io.github.jan.supabase.auth.user.UserSession
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Needs a real AndroidKeyStore, so this runs on-device/emulator rather than
 * as a JVM unit test -- see docs/SECURITY.md §10's "Token storage" row.
 */
@RunWith(AndroidJUnit4::class)
class EncryptedSessionManagerTest {

    private lateinit var manager: EncryptedSessionManager

    @Before fun setUp() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        manager = EncryptedSessionManager(context)
        runBlocking { manager.deleteSession() }
    }

    @Test fun loadSessionReturnsNullWhenNothingWasEverSaved() = runBlocking {
        assertNull(manager.loadSession())
    }

    @Test fun savedSessionRoundTripsExactly() = runBlocking {
        val session = UserSession(
            accessToken = "access-token-value",
            refreshToken = "refresh-token-value",
            expiresIn = 3600L,
            tokenType = "bearer",
        )

        manager.saveSession(session)
        val loaded = manager.loadSession()

        assertEquals(session.accessToken, loaded?.accessToken)
        assertEquals(session.refreshToken, loaded?.refreshToken)
        assertEquals(session.tokenType, loaded?.tokenType)
    }

    @Test fun deleteSessionClearsAPreviouslySavedSession() = runBlocking {
        manager.saveSession(
            UserSession(
                accessToken = "access-token-value",
                refreshToken = "refresh-token-value",
                expiresIn = 3600L,
                tokenType = "bearer",
            ),
        )

        manager.deleteSession()

        assertNull(manager.loadSession())
    }

    @Test fun sessionIsNotStoredAsPlaintextInSharedPreferences() = runBlocking {
        val secretToken = "super-secret-access-token-value"
        manager.saveSession(
            UserSession(
                accessToken = secretToken,
                refreshToken = "refresh-token-value",
                expiresIn = 3600L,
                tokenType = "bearer",
            ),
        )

        val context = ApplicationProvider.getApplicationContext<Context>()
        val rawPrefsContents = context
            .getSharedPreferences("kasihkirim_session_enc", Context.MODE_PRIVATE)
            .all
            .values
            .joinToString()

        assertEquals(false, rawPrefsContents.contains(secretToken))
    }
}
