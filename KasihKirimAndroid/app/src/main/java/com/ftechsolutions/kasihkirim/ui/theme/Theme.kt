package com.ftechsolutions.kasihkirim.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

// Brand tokens carried over from apps/mobile/src/ui/tokens.ts, which derives
// them from the pitch deck: deep forest green, gold, warm orange on cream.
private val Green900 = Color(0xFF123D28)
private val Green600 = Color(0xFF2D7A52)
private val Gold     = Color(0xFFF5C542)
private val Orange   = Color(0xFFE8811E)
private val Cream    = Color(0xFFFDF7EA)
private val Ink      = Color(0xFF12261C)

private val Light = lightColorScheme(
    primary = Green900, onPrimary = Color.White,
    secondary = Green600, onSecondary = Color.White,
    tertiary = Gold, onTertiary = Ink,
    background = Cream, onBackground = Ink,
    surface = Color.White, onSurface = Ink,
    error = Color(0xFFC2401F),
)

private val Dark = darkColorScheme(
    primary = Gold, onPrimary = Ink,
    secondary = Green600, onSecondary = Color.White,
    tertiary = Orange, onTertiary = Ink,
)

@Composable
fun KasihKirimTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) = MaterialTheme(colorScheme = if (darkTheme) Dark else Light, content = content)
