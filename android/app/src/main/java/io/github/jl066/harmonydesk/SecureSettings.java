package io.github.jl066.harmonydesk;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.Key;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.util.Arrays;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/**
 * Synchronously persisted, Android Keystore encrypted settings.
 *
 * <p>Logical setting names are hashed before they are used as preference names. Values are
 * encrypted with AES-GCM and authenticated against that hashed name. If the Keystore key is
 * unavailable or invalidated, reads and writes fail closed; this class never falls back to
 * plaintext or silently erases the preferences.</p>
 */
public final class SecureSettings {
    private static final String PREFERENCES = "secure_settings_v1";
    private static final String KEY_ALIAS = "io.github.jl066.harmonydesk.secure_settings.v1";
    private static final String KEYSTORE = "AndroidKeyStore";
    private static final String AES_GCM = "AES/GCM/NoPadding";
    private static final int IV_LENGTH_BYTES = 12;
    private static final int TAG_LENGTH_BITS = 128;
    private static final Object KEY_LOCK = new Object();

    private final SharedPreferences preferences;

    public SecureSettings(Context context) {
        if (context == null) {
            throw new IllegalArgumentException("context must not be null");
        }
        Context appContext = context.getApplicationContext();
        this.preferences = (appContext != null ? appContext : context)
                .getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE);
    }

    /** Returns the decrypted value, or {@code fallback} only when the setting is absent. */
    public synchronized String get(String key, String fallback) {
        String preferenceKey = preferenceKey(key);
        final String encoded;
        try {
            encoded = preferences.getString(preferenceKey, null);
        } catch (RuntimeException e) {
            throw new SecureSettingsException("Could not read secure setting", e);
        }
        if (encoded == null) {
            return fallback;
        }

        try {
            byte[] encrypted = Base64.decode(encoded, Base64.NO_WRAP);
            if (encrypted.length <= IV_LENGTH_BYTES) {
                throw new GeneralSecurityException("Invalid encrypted setting");
            }
            byte[] iv = Arrays.copyOfRange(encrypted, 0, IV_LENGTH_BYTES);
            byte[] ciphertext = Arrays.copyOfRange(encrypted, IV_LENGTH_BYTES, encrypted.length);
            Cipher cipher = Cipher.getInstance(AES_GCM);
            cipher.init(Cipher.DECRYPT_MODE, getOrCreateKey(), new GCMParameterSpec(TAG_LENGTH_BITS, iv));
            cipher.updateAAD(preferenceKey.getBytes(StandardCharsets.UTF_8));
            return new String(cipher.doFinal(ciphertext), StandardCharsets.UTF_8);
        } catch (GeneralSecurityException | IOException | IllegalArgumentException e) {
            throw new SecureSettingsException("Could not decrypt secure setting", e);
        }
    }

    /** Encrypts and synchronously persists a value. A null value is rejected. */
    public synchronized void put(String key, String value) {
        if (value == null) {
            throw new IllegalArgumentException("value must not be null");
        }
        String preferenceKey = preferenceKey(key);
        try {
            Cipher cipher = Cipher.getInstance(AES_GCM);
            cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey());
            cipher.updateAAD(preferenceKey.getBytes(StandardCharsets.UTF_8));
            byte[] iv = cipher.getIV();
            byte[] ciphertext = cipher.doFinal(value.getBytes(StandardCharsets.UTF_8));
            byte[] encrypted = new byte[iv.length + ciphertext.length];
            System.arraycopy(iv, 0, encrypted, 0, iv.length);
            System.arraycopy(ciphertext, 0, encrypted, iv.length, ciphertext.length);
            String encoded = Base64.encodeToString(encrypted, Base64.NO_WRAP);
            if (!preferences.edit().putString(preferenceKey, encoded).commit()) {
                throw new SecureSettingsException("Could not persist secure setting");
            }
        } catch (GeneralSecurityException | IOException e) {
            throw new SecureSettingsException("Could not encrypt secure setting", e);
        }
    }

    /** Removes only the named value; this operation does not need the Keystore key. */
    public synchronized void remove(String key) {
        String preferenceKey = preferenceKey(key);
        try {
            if (!preferences.edit().remove(preferenceKey).commit()) {
                throw new SecureSettingsException("Could not remove secure setting");
            }
        } catch (RuntimeException e) {
            if (e instanceof SecureSettingsException) {
                throw e;
            }
            throw new SecureSettingsException("Could not remove secure setting", e);
        }
    }

    private static String preferenceKey(String key) {
        if (key == null || key.isEmpty()) {
            throw new IllegalArgumentException("key must not be empty");
        }
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256")
                    .digest(key.getBytes(StandardCharsets.UTF_8));
            StringBuilder result = new StringBuilder("v1_");
            for (byte value : digest) {
                result.append(Character.forDigit((value >>> 4) & 0x0f, 16));
                result.append(Character.forDigit(value & 0x0f, 16));
            }
            return result.toString();
        } catch (GeneralSecurityException e) {
            throw new SecureSettingsException("Could not prepare secure setting", e);
        }
    }

    private SecretKey getOrCreateKey() throws GeneralSecurityException, IOException {
        synchronized (KEY_LOCK) {
            KeyStore keyStore = KeyStore.getInstance(KEYSTORE);
            keyStore.load(null);
            if (keyStore.containsAlias(KEY_ALIAS)) {
                Key existing = keyStore.getKey(KEY_ALIAS, null);
                if (existing instanceof SecretKey) {
                    return (SecretKey) existing;
                }
                throw new GeneralSecurityException("Keystore key is unavailable");
            }
            if (!preferences.getAll().isEmpty()) {
                // Existing ciphertext with a missing alias cannot be recovered. Generating a
                // replacement would make new writes appear healthy while old values stay lost.
                throw new GeneralSecurityException("Keystore key is unavailable for stored settings");
            }

            KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE);
            generator.init(new KeyGenParameterSpec.Builder(KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build());
            return generator.generateKey();
        }
    }

    /** Unchecked failure that callers can catch without exposing secret values in logs. */
    public static final class SecureSettingsException extends RuntimeException {
        public SecureSettingsException(String message) {
            super(message);
        }

        public SecureSettingsException(String message, Throwable cause) {
            super(message, cause);
        }
    }
}
