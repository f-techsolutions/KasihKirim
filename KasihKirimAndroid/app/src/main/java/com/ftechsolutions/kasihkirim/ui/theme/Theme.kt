package com.ftechsolutions.kasihkirim.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

// Brand tokens carried over from apps/mobile/src/ui/tokens.ts, which derives
// them from the pitch deck: deep forest green, gold, warm orange on cream.
private val Green900 = Color(0xFF123D28)
private val Green600 = Color(0xFF2D7A52)
private val Green100 = Color(0xFFE3EFE6)   // tonal surface for cards/chips on Light
private val Gold     = Color(0xFFF5C542)
private val GoldDeep = Color(0xFFB8862A)   // readable-on-cream ink for gold badges
private val Orange   = Color(0xFFE8811E)
private val Cream    = Color(0xFFFDF7EA)
private val Ink      = Color(0xFF12261C)
private val InkMuted = Color(0xFF5B6E62)
private val Line     = Color(0xFFDCD3BE)
private val Surface1Dark = Color(0xFF16211A)
private val Green100Dark = Color(0xFF1F3327)

private val Light = lightColorScheme(
    primary = Green900, onPrimary = Color.White,
    primaryContainer = Green100, onPrimaryContainer = Green900,
    secondary = Green600, onSecondary = Color.White,
    secondaryContainer = Green100, onSecondaryContainer = Green900,
    tertiary = GoldDeep, onTertiary = Color.White,
    tertiaryContainer = Gold, onTertiaryContainer = Ink,
    background = Cream, onBackground = Ink,
    surface = Color.White, onSurface = Ink,
    surfaceVariant = Color(0xFFF3EEDD), onSurfaceVariant = InkMuted,
    outline = Line, outlineVariant = Color(0xFFEAE3CF),
    error = Color(0xFFB3261E), onError = Color.White,
    errorContainer = Color(0xFFFBE9E7), onErrorContainer = Color(0xFF8C1D14),
)

private val Dark = darkColorScheme(
    primary = Gold, onPrimary = Ink,
    primaryContainer = Green100Dark, onPrimaryContainer = Gold,
    secondary = Green600, onSecondary = Color.White,
    secondaryContainer = Green100Dark, onSecondaryContainer = Color(0xFFB7D9C4),
    tertiary = Orange, onTertiary = Ink,
    tertiaryContainer = Color(0xFF4A3313), onTertiaryContainer = Orange,
    background = Color(0xFF0E140F), onBackground = Color(0xFFEAEFE9),
    surface = Surface1Dark, onSurface = Color(0xFFEAEFE9),
    surfaceVariant = Color(0xFF23302A), onSurfaceVariant = Color(0xFFB4C2BA),
    outline = Color(0xFF3B4A41), outlineVariant = Color(0xFF2A362F),
    error = Color(0xFFEFB4A9), onError = Color(0xFF601410),
)

// A restrained type scale: bold, tight-tracking headings so labels like
// "KasihKirim" and section titles read as designed rather than default
// Material, and a slightly larger body size for readability on the small,
// often-older-hardware screens this app targets (docs/ANDROID.md §1).
private val AppTypography = Typography().let { base ->
    base.copy(
        headlineLarge = base.headlineLarge.copy(
            fontWeight = FontWeight.Bold, letterSpacing = (-0.5).sp),
        headlineSmall = base.headlineSmall.copy(
            fontWeight = FontWeight.Bold, letterSpacing = (-0.25).sp),
        titleLarge = base.titleLarge.copy(fontWeight = FontWeight.SemiBold),
        titleMedium = base.titleMedium.copy(fontWeight = FontWeight.SemiBold),
        titleSmall = base.titleSmall.copy(fontWeight = FontWeight.SemiBold),
        bodyLarge = base.bodyLarge.copy(fontSize = 16.sp, lineHeight = 24.sp),
        bodyMedium = base.bodyMedium.copy(lineHeight = 20.sp),
        labelLarge = base.labelLarge.copy(fontWeight = FontWeight.SemiBold),
        labelSmall = base.labelSmall.copy(
            fontWeight = FontWeight.SemiBold, letterSpacing = 0.6.sp),
    )
}

// Friendlier, more rounded corners than Material3's defaults -- this alone
// lifts text fields, cards and buttons across every screen that reads
// MaterialTheme.shapes, with zero per-screen changes.
private val AppShapes = Shapes(
    extraSmall = RoundedCornerShape(10.dp),
    small = RoundedCornerShape(12.dp),
    medium = RoundedCornerShape(16.dp),
    large = RoundedCornerShape(20.dp),
    extraLarge = RoundedCornerShape(28.dp),
)

@Composable
fun KasihKirimTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) = MaterialTheme(
    colorScheme = if (darkTheme) Dark else Light,
    typography = AppTypography,
    shapes = AppShapes,
    content = content,
)
