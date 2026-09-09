package com.ftechsolutions.kasihkirim.ui.common

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.unit.dp

/** The one card shape used everywhere -- rounded corners, a hairline of
 *  elevation, the theme's surface color -- so every list of things (an
 *  address, a trip, an order, a vehicle) reads as the same kind of object
 *  instead of each screen inventing its own card. */
@Composable
fun AppCard(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Surface(
        shape = MaterialTheme.shapes.large,
        color = MaterialTheme.colorScheme.surface,
        shadowElevation = 1.dp,
        tonalElevation = 1.dp,
        modifier = modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(18.dp), content = content)
    }
}

/** A screen's title, with an optional one-line subtitle underneath it --
 *  replaces the bare headlineSmall + Spacer every screen used to repeat. */
@Composable
fun ScreenHeader(title: String, subtitle: String? = null) {
    Column {
        Text(
            title,
            style = MaterialTheme.typography.headlineSmall,
            color = MaterialTheme.colorScheme.onBackground,
        )
        if (subtitle != null) {
            Spacer(Modifier.height(2.dp))
            Text(
                subtitle,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/** A bordered placeholder card for "nothing here yet" states -- replaces a
 *  single line of grey text with something that actually looks designed,
 *  and can carry a hint about what to do next. */
@Composable
fun EmptyStateCard(title: String, hint: String? = null) {
    Surface(
        shape = MaterialTheme.shapes.large,
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(20.dp)) {
            Text(
                title,
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.onSurface,
            )
            if (hint != null) {
                Spacer(Modifier.height(4.dp))
                Text(
                    hint,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

/** A primary-to-secondary diagonal gradient card, used for the one or two
 *  "headline" surfaces per screen (a balance, a success state) that should
 *  read as more prominent than an ordinary AppCard. */
@Composable
fun GradientHeroCard(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Surface(
        shape = MaterialTheme.shapes.extraLarge,
        color = MaterialTheme.colorScheme.primary,
        modifier = modifier.fillMaxWidth(),
    ) {
        Box(
            Modifier
                .background(
                    Brush.linearGradient(
                        listOf(MaterialTheme.colorScheme.primary, MaterialTheme.colorScheme.secondary),
                    ),
                )
                .padding(24.dp),
        ) { content() }
    }
}

enum class BadgeTone { NEUTRAL, POSITIVE, WARNING, INFO, ERROR }

/** A small rounded label for a status word (order/trip/vehicle state, a
 *  Beli/Hantar tag, "Utama") -- one visual language for every screen that
 *  used to just print the word as plain text. */
@Composable
fun StatusBadge(text: String, tone: BadgeTone = BadgeTone.NEUTRAL) {
    val (container, content) = when (tone) {
        BadgeTone.NEUTRAL -> MaterialTheme.colorScheme.surfaceVariant to MaterialTheme.colorScheme.onSurfaceVariant
        BadgeTone.POSITIVE -> MaterialTheme.colorScheme.secondaryContainer to MaterialTheme.colorScheme.onSecondaryContainer
        BadgeTone.WARNING -> MaterialTheme.colorScheme.tertiaryContainer to MaterialTheme.colorScheme.onTertiaryContainer
        BadgeTone.INFO -> MaterialTheme.colorScheme.primaryContainer to MaterialTheme.colorScheme.onPrimaryContainer
        BadgeTone.ERROR -> MaterialTheme.colorScheme.errorContainer to MaterialTheme.colorScheme.onErrorContainer
    }
    Surface(shape = MaterialTheme.shapes.extraLarge, color = container) {
        Text(
            text,
            style = MaterialTheme.typography.labelSmall,
            color = content,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
        )
    }
}
