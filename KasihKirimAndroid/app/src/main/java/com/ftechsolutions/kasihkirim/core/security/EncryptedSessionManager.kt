package com.ftechsolutions.kasihkirim.core.security

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.github.jan.supabase.auth.SessionManager
import io.github.jan.supabase.auth.user.UserSession
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Encrypts the Supabase auth session (access + refresh tokens) at rest with
 * an AndroidKeyStore-backed AES-256-GCM key before writing it to a private
 * SharedPreferences file.
 *
 * Without this, supabase-kt's Auth plugin falls back to its own default
 * SessionManager (SettingsSessionManager, from the `multiplatform-settings`
 * library), which on Android writes the session to a plain, unencrypted
 * SharedPreferences file auto-initialized via an androidx.startup
 * Initializer -- confirmed by reading multiplatform-settings-no-arg-android
 * 1.3.0's source directly (the version auth-kt-android 3.5.0 pulls in).
 *
 * androidx.security.crypto's EncryptedSharedPreferences was considered
 * instead, but its entire API was deprecated in 1.1.0-beta01 (June 2025):
 * "Deprecated all APIs in favour of existing platform APIs and direct use
 * of Android Keystore" -- confirmed from the library's own release notes.
 * This implements that recommended replacement directly.
 */
class EncryptedSessionManager(context: Context) : SessionManager {

    private val prefs = context.applicationContext
        .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    private val json = Json { encodeDefaults = true }

    override suspend fun saveSession(session: UserSession) = withContext(Dispatchers.IO) {
        val plaintext = json.encodeToString(UserSession.serializer(), session).encodeToByteArray()
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
        val ciphertext = cipher.doFinal(plaintext)
        prefs.edit()
            .putString(KEY_IV, Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .putString(KEY_CIPHERTEXT, Base64.encodeToString(ciphertext, Base64.NO_WRAP))
            .apply()
    }

    override suspend fun loadSession(): UserSession? = withContext(Dispatchers.IO) {
        val ivB64 = prefs.getString(KEY_IV, null)
        val ciphertextB64 = prefs.getString(KEY_CIPHERTEXT, null)
        if (ivB64 == null || ciphertextB64 == null) return@withContext null
        try {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(
                Cipher.DECRYPT_MODE,
                getOrCreateKey(),
                GCMParameterSpec(GCM_TAG_LENGTH_BITS, Base64.decode(ivB64, Base64.NO_WRAP)),
            )
            val plaintext = cipher.doFinal(Base64.decode(ciphertextB64, Base64.NO_WRAP))
            json.decodeFromString(UserSession.serializer(), plaintext.decodeToString())
        } catch (e: Exception) {
            // A corrupted or undecryptable session (e.g. the Keystore key
            // was lost, as can happen across a device restore) should sign
            // the user out, never crash the app on launch.
            deleteSession()
            null
        }
    }

    override suspend fun deleteSession() = withContext(Dispatchers.IO) {
        prefs.edit().clear().apply()
    }

    private fun getOrCreateKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }

        val keyGenerator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        keyGenerator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return keyGenerator.generateKey()
    }

    private companion object {
        const val PREFS_NAME = "kasihkirim_session_enc"
        const val KEY_IV = "iv"
        const val KEY_CIPHERTEXT = "ciphertext"
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val KEY_ALIAS = "kasihkirim_session_key"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val GCM_TAG_LENGTH_BITS = 128
    }
}
