@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.ftechsolutions.kasihkirim.ui.common

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.ftechsolutions.kasihkirim.domain.model.Community

internal enum class NoticeTone { ERROR, HINT }

@Composable
internal fun InlineNotice(text: String, tone: NoticeTone) {
    val (container, content) = when (tone) {
        NoticeTone.ERROR -> MaterialTheme.colorScheme.errorContainer to MaterialTheme.colorScheme.onErrorContainer
        NoticeTone.HINT -> MaterialTheme.colorScheme.surfaceVariant to MaterialTheme.colorScheme.onSurfaceVariant
    }
    Surface(shape = MaterialTheme.shapes.small, color = container, modifier = Modifier.fillMaxWidth()) {
        Text(
            text,
            style = MaterialTheme.typography.bodySmall,
            color = content,
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
        )
    }
}

/** Typing a name here never selected anything on its own -- only tapping a
 *  result did -- so a `canSubmit`/`canQuote`-style gate could stay false with
 *  no visible reason why. This gives the field two unambiguous states:
 *  searching (with a hint and a dropdown you tap) and selected (a locked
 *  pill with an explicit "Tukar" to go back and search again). Shared by
 *  the Addresses form and the Kirim quote form, which both pick a
 *  Community the same way. */
@Composable
internal fun CommunityPicker(
    label: String,
    hint: String,
    changeLabel: String,
    notSelectedHint: String,
    query: String,
    selected: Community?,
    results: List<Community>,
    onQueryChange: (String) -> Unit,
    onSelect: (Community) -> Unit,
    onClear: () -> Unit,
) {
    Column {
        if (selected != null) {
            Surface(
                shape = MaterialTheme.shapes.small,
                color = MaterialTheme.colorScheme.secondaryContainer,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Row(
                    Modifier.padding(horizontal = 14.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(
                            label,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSecondaryContainer,
                        )
                        Text(
                            "${selected.name}, ${selected.district}",
                            style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold),
                            color = MaterialTheme.colorScheme.onSecondaryContainer,
                        )
                    }
                    TextButton(onClick = onClear) { Text(changeLabel) }
                }
            }
        } else {
            OutlinedTextField(
                value = query,
                onValueChange = onQueryChange,
                label = { Text(label) },
                singleLine = true,
                shape = MaterialTheme.shapes.small,
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(6.dp))
            Text(
                hint,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )

            if (results.isNotEmpty()) {
                Spacer(Modifier.height(8.dp))
                Surface(
                    shape = MaterialTheme.shapes.small,
                    color = MaterialTheme.colorScheme.surface,
                    border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Column {
                        results.forEachIndexed { index, community ->
                            if (index > 0) {
                                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                            }
                            Row(
                                Modifier
                                    .fillMaxWidth()
                                    .clickable { onSelect(community) }
                                    .padding(horizontal = 14.dp, vertical = 12.dp),
                            ) {
                                Text(
                                    "${community.name}, ${community.district}",
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurface,
                                )
                            }
                        }
                    }
                }
            } else if (query.isNotBlank()) {
                Spacer(Modifier.height(10.dp))
                InlineNotice(text = notSelectedHint, tone = NoticeTone.HINT)
            }
        }
    }
}
