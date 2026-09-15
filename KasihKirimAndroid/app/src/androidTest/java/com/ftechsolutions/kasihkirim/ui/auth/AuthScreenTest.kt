package com.ftechsolutions.kasihkirim.ui.auth

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.AuthState
import com.ftechsolutions.kasihkirim.domain.model.AuthUser
import com.ftechsolutions.kasihkirim.domain.repository.AuthRepository
import com.ftechsolutions.kasihkirim.ui.theme.KasihKirimTheme
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.junit.Rule
import org.junit.Test

/** Same fake shape as ui/auth/AuthViewModelTest.kt (JVM) -- androidTest and
 *  test are separate source sets, so it's redeclared rather than shared. */
private class FakeAuthRepository(
    var result: AppResult<AuthUser> = AppResult.Failure(AppError.InvalidCredentials),
) : AuthRepository {
    private val state = MutableStateFlow<AuthState>(AuthState.Unauthenticated)
    override val authState: StateFlow<AuthState> = state
    override suspend fun restoreSession() { /* already Unauthenticated */ }
    override suspend fun signUpWithEmail(email: String, password: String) = result
    override suspend fun signInWithEmail(email: String, password: String) = result
    override suspend fun signOut(): AppResult<Unit> {
        state.value = AuthState.Unauthenticated
        return AppResult.Success(Unit)
    }
}

/** First instrumented UI test in this module (Phase 10 / docs/TESTING.md §8's
 *  "Compose UI tests for auth..." gate) -- runs against a real Compose
 *  semantics tree on a device/emulator, never against real Supabase: the
 *  fake above is the only AuthRepository these tests ever see. */
class AuthScreenTest {

    @get:Rule val composeRule = createComposeRule()

    @Test fun signInButtonIsDisabledUntilEmailAndPasswordAreValid() {
        composeRule.setContent {
            KasihKirimTheme { AuthScreen(AuthViewModel(FakeAuthRepository())) }
        }
        composeRule.waitForIdle()

        composeRule.onNodeWithText("Log Masuk").assertIsNotEnabled()

        composeRule.onNodeWithText("E-mel").performTextInput("aisyah@example.com")
        composeRule.onNodeWithText("Kata laluan").performTextInput("longenough123")

        composeRule.onNodeWithText("Log Masuk").assertIsEnabled()
    }

    @Test fun aFailedSignInShowsTheErrorMessageAndStaysOnTheForm() {
        composeRule.setContent {
            KasihKirimTheme {
                AuthScreen(AuthViewModel(FakeAuthRepository(AppResult.Failure(AppError.InvalidCredentials))))
            }
        }
        composeRule.waitForIdle()

        composeRule.onNodeWithText("E-mel").performTextInput("aisyah@example.com")
        composeRule.onNodeWithText("Kata laluan").performTextInput("wrongpassword")
        composeRule.onNodeWithText("Log Masuk").performClick()
        composeRule.waitForIdle()

        composeRule.onNodeWithText("E-mel atau kata laluan salah.").assertIsDisplayed()
    }

    @Test fun switchingToSignUpChangesTheSubmitButtonLabel() {
        composeRule.setContent {
            KasihKirimTheme { AuthScreen(AuthViewModel(FakeAuthRepository())) }
        }
        composeRule.waitForIdle()

        composeRule.onNodeWithText("Belum ada akaun? Daftar").performClick()

        composeRule.onNodeWithText("Daftar").assertIsDisplayed()
    }
}
