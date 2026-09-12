package com.ftechsolutions.kasihkirim.ui.auth

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.AuthState
import com.ftechsolutions.kasihkirim.domain.model.AuthUser
import com.ftechsolutions.kasihkirim.domain.model.UserRole
import com.ftechsolutions.kasihkirim.domain.repository.AuthRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.test.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

private class FakeAuthRepository(
    var signInResult: AppResult<AuthUser> = AppResult.Success(
        AuthUser("u1", "a@b.com", setOf(UserRole.CUSTOMER), null, null, "active")
    ),
    var resetResult: AppResult<Unit> = AppResult.Success(Unit),
) : AuthRepository {
    val state = MutableStateFlow<AuthState>(AuthState.Initializing)
    override val authState: StateFlow<AuthState> = state
    var restoreCalls = 0
    var signOutCalls = 0
    var resetCalls = 0
    var lastResetEmail: String? = null

    override suspend fun restoreSession() { restoreCalls++; state.value = AuthState.Unauthenticated }
    override suspend fun signUpWithEmail(email: String, password: String) = signInResult
    override suspend fun signInWithEmail(email: String, password: String) = signInResult
    override suspend fun signOut(): AppResult<Unit> {
        signOutCalls++; state.value = AuthState.Unauthenticated; return AppResult.Success(Unit)
    }

    override suspend fun sendPasswordReset(email: String): AppResult<Unit> {
        resetCalls++; lastResetEmail = email; return resetResult
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class AuthViewModelTest {

    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    @Test fun `restores session on construction`() = runTest(dispatcher) {
        val repo = FakeAuthRepository()
        AuthViewModel(repo)
        advanceUntilIdle()
        assertEquals(1, repo.restoreCalls)
    }

    @Test fun `submit is blocked until email and password are valid`() = runTest(dispatcher) {
        val vm = AuthViewModel(FakeAuthRepository()); advanceUntilIdle()
        assertFalse(vm.form.value.canSubmit)
        vm.onEmailChange("aisyah@example.com")
        assertFalse("password still missing", vm.form.value.canSubmit)
        vm.onPasswordChange("short")
        assertFalse("password under 8 chars", vm.form.value.canSubmit)
        vm.onPasswordChange("longenough123")
        assertTrue(vm.form.value.canSubmit)
    }

    @Test fun `failed sign in surfaces a domain error and keeps the user on the form`() =
        runTest(dispatcher) {
            val repo = FakeAuthRepository(AppResult.Failure(AppError.InvalidCredentials))
            val vm = AuthViewModel(repo); advanceUntilIdle()
            vm.onEmailChange("a@b.com"); vm.onPasswordChange("wrongpassword")
            vm.signIn(); advanceUntilIdle()
            assertEquals(AppError.InvalidCredentials, vm.form.value.error)
            assertFalse(vm.form.value.isSubmitting)
        }

    /** The password must not survive a successful sign-in. */
    @Test fun `successful sign in clears the credential fields`() = runTest(dispatcher) {
        val vm = AuthViewModel(FakeAuthRepository()); advanceUntilIdle()
        vm.onEmailChange("a@b.com"); vm.onPasswordChange("correcthorse")
        vm.signIn(); advanceUntilIdle()
        assertEquals("", vm.form.value.password)
        assertEquals("", vm.form.value.email)
    }

    @Test fun `sign out clears the form and delegates to the repository`() = runTest(dispatcher) {
        val repo = FakeAuthRepository()
        val vm = AuthViewModel(repo); advanceUntilIdle()
        vm.onEmailChange("a@b.com"); vm.onPasswordChange("correcthorse")
        vm.signOut(); advanceUntilIdle()
        assertEquals(1, repo.signOutCalls)
        assertEquals("", vm.form.value.password)
    }

    @Test fun `sendPasswordReset sends the typed email and shows a confirmation`() = runTest(dispatcher) {
        val repo = FakeAuthRepository()
        val vm = AuthViewModel(repo); advanceUntilIdle()
        vm.onEmailChange("aisyah@example.com")

        vm.sendPasswordReset(); advanceUntilIdle()

        assertEquals(1, repo.resetCalls)
        assertEquals("aisyah@example.com", repo.lastResetEmail)
        assertTrue(vm.form.value.resetEmailSent)
        assertFalse(vm.form.value.isSendingReset)
        assertNull(vm.form.value.error)
    }

    @Test fun `sendPasswordReset does nothing without a valid email`() = runTest(dispatcher) {
        val repo = FakeAuthRepository()
        val vm = AuthViewModel(repo); advanceUntilIdle()
        vm.onEmailChange("not-an-email")

        vm.sendPasswordReset(); advanceUntilIdle()

        assertEquals("an invalid email must never reach the repository", 0, repo.resetCalls)
        assertFalse(vm.form.value.resetEmailSent)
    }

    @Test fun `a failed sendPasswordReset surfaces the error and clears the busy flag`() = runTest(dispatcher) {
        val repo = FakeAuthRepository(resetResult = AppResult.Failure(AppError.Network))
        val vm = AuthViewModel(repo); advanceUntilIdle()
        vm.onEmailChange("aisyah@example.com")

        vm.sendPasswordReset(); advanceUntilIdle()

        assertEquals(AppError.Network, vm.form.value.error)
        assertFalse(vm.form.value.isSendingReset)
        assertFalse(vm.form.value.resetEmailSent)
    }

    @Test fun `editing the email after a reset was sent clears the stale confirmation`() = runTest(dispatcher) {
        val repo = FakeAuthRepository()
        val vm = AuthViewModel(repo); advanceUntilIdle()
        vm.onEmailChange("aisyah@example.com")
        vm.sendPasswordReset(); advanceUntilIdle()
        assertTrue(vm.form.value.resetEmailSent)

        vm.onEmailChange("aisyah2@example.com")

        assertFalse(vm.form.value.resetEmailSent)
    }

    @Test fun `sendPasswordReset never touches sign-in submission state`() = runTest(dispatcher) {
        val repo = FakeAuthRepository()
        val vm = AuthViewModel(repo); advanceUntilIdle()
        vm.onEmailChange("aisyah@example.com"); vm.onPasswordChange("longenough123")

        vm.sendPasswordReset(); advanceUntilIdle()

        assertFalse(vm.form.value.isSubmitting)
        assertTrue("password reset must not clear an in-progress sign-in form", vm.form.value.canSubmit)
    }
}
