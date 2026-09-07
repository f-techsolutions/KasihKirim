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
) : AuthRepository {
    val state = MutableStateFlow<AuthState>(AuthState.Initializing)
    override val authState: StateFlow<AuthState> = state
    var restoreCalls = 0
    var signOutCalls = 0

    override suspend fun restoreSession() { restoreCalls++; state.value = AuthState.Unauthenticated }
    override suspend fun signUpWithEmail(email: String, password: String) = signInResult
    override suspend fun signInWithEmail(email: String, password: String) = signInResult
    override suspend fun signOut(): AppResult<Unit> {
        signOutCalls++; state.value = AuthState.Unauthenticated; return AppResult.Success(Unit)
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
}
