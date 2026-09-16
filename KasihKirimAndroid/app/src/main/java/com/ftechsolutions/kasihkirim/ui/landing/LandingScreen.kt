package com.ftechsolutions.kasihkirim.ui.landing

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.LocalShipping
import androidx.compose.material.icons.filled.NearMe
import androidx.compose.material.icons.filled.Storefront
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.ftechsolutions.kasihkirim.R
import com.ftechsolutions.kasihkirim.ui.common.AppCard

/**
 * The very first screen an unauthenticated user sees (App.kt) -- what
 * AuthScreen used to be on its own. Separated out so there's a place to
 * actually explain what KasihKirim does before asking for an e-mel and
 * kata laluan; "Mula Hantar" is the only way into AuthScreen from here.
 */
@Composable
fun LandingScreen(onMulaHantar: () -> Unit) {
    Box(Modifier.fillMaxSize()) {
        Image(
            painter = painterResource(R.drawable.bg_landing),
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier.fillMaxSize(),
        )

        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Spacer(Modifier.height(56.dp))

            Surface(
                shape = MaterialTheme.shapes.large,
                color = MaterialTheme.colorScheme.surface,
                shadowElevation = 4.dp,
                modifier = Modifier.size(96.dp),
            ) {
                Image(
                    painter = painterResource(R.drawable.logo_kasihkirim),
                    contentDescription = stringResource(R.string.app_name),
                    modifier = Modifier.padding(10.dp).clip(MaterialTheme.shapes.medium),
                )
            }
            Spacer(Modifier.height(16.dp))
            Text(
                stringResource(R.string.app_name),
                style = MaterialTheme.typography.headlineLarge.copy(fontWeight = FontWeight.Bold),
                color = MaterialTheme.colorScheme.primary,
            )
            Spacer(Modifier.height(6.dp))
            Text(
                stringResource(R.string.tagline),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(24.dp))

            AppCard {
                Text(
                    stringResource(R.string.landing_intro),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Spacer(Modifier.height(16.dp))
                LandingFeature(Icons.Filled.LocalShipping, stringResource(R.string.landing_feature_send))
                Spacer(Modifier.height(10.dp))
                LandingFeature(Icons.Filled.Storefront, stringResource(R.string.landing_feature_shop))
                Spacer(Modifier.height(10.dp))
                LandingFeature(Icons.Filled.NearMe, stringResource(R.string.landing_feature_track))
            }

            // A fixed gap, not Modifier.weight: this Column is inside a
            // verticalScroll, whose unbounded height makes weight() throw.
            Spacer(Modifier.height(40.dp))
            Button(
                onClick = onMulaHantar,
                shape = MaterialTheme.shapes.medium,
                modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp),
            ) {
                Text(
                    stringResource(R.string.landing_mula_hantar),
                    style = MaterialTheme.typography.labelLarge,
                )
            }
            Spacer(Modifier.height(32.dp))
        }
    }
}

@Composable
private fun LandingFeature(icon: ImageVector, text: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
        Spacer(Modifier.width(12.dp))
        Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurface)
    }
}
