package com.motobridge.android

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/** Guía "Maximizar compatibilidad (hotspot)". Sin red ni riders conectados.
 *  Texto en res/values/strings.xml (hotspot_*). Se abre desde Configuración. */
@Composable
fun HotspotGuideCard() {
    var open by remember { mutableStateOf(false) }
    val sections = listOf(
        R.string.hotspot_iphone_title to listOf(R.string.hotspot_iphone_1, R.string.hotspot_iphone_2, R.string.hotspot_iphone_3, R.string.hotspot_iphone_4),
        R.string.hotspot_android_title to listOf(R.string.hotspot_android_1, R.string.hotspot_android_2, R.string.hotspot_android_3, R.string.hotspot_android_4),
        R.string.hotspot_noaudio_title to listOf(R.string.hotspot_noaudio_1, R.string.hotspot_noaudio_2),
        R.string.hotspot_range_title to listOf(R.string.hotspot_range_1)
    )
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            TextButton(onClick = { open = !open }) {
                Text(stringResource(R.string.hotspot_title), fontWeight = FontWeight.Bold)
            }
            if (open) {
                Text(stringResource(R.string.hotspot_intro))
                for ((title, steps) in sections) {
                    Text(stringResource(title), fontWeight = FontWeight.SemiBold)
                    for (step in steps) {
                        val text = stringResource(step)
                        Text(text, modifier = Modifier.semantics { contentDescription = text })
                    }
                }
            }
        }
    }
}
