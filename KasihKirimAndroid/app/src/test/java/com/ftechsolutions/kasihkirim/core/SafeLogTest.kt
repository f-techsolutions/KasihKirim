package com.ftechsolutions.kasihkirim.core

import com.ftechsolutions.kasihkirim.core.security.SafeLog
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** §4: tokens, OTPs, passwords and keys must never reach a log sink. */
class SafeLogTest {

    @Test fun `redacts a JWT`() {
        val jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1MSJ9.abcdefghijKLMNOP123"
        assertFalse(SafeLog.redact("token=$jwt").contains("eyJ"))
    }

    @Test fun `redacts a publishable key`() {
        assertFalse(SafeLog.redact("key sb_publishable_abc123XYZ").contains("sb_publishable_abc123XYZ"))
    }

    @Test fun `redacts password and otp fields`() {
        assertFalse(SafeLog.redact("password=hunter2").contains("hunter2"))
        assertTrue(SafeLog.redact("otp: 123456").contains("[REDACTED]"))
    }

    @Test fun `redacts a Malaysian phone number`() {
        assertFalse(SafeLog.redact("+60128889999 signed in").contains("+60128889999"))
    }

    @Test fun `leaves harmless text intact`() {
        assertTrue(SafeLog.redact("kirim POSTED -> MATCHED").contains("MATCHED"))
    }
}
