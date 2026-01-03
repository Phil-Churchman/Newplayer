package com.example.newplayer

import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.core.content.ContextCompat
import com.example.player.data.Profile

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProfilesScreen(viewModel: ProfilesViewModel) {
    val uiState by viewModel.uiState.collectAsState()
    var showDialog by remember { mutableStateOf(false) }
    var profileToEdit by remember { mutableStateOf<Profile?>(null) }
    var showDeleteConfirmation by remember { mutableStateOf<Profile?>(null) }
    val localProfileExists = uiState.profiles.any { it.name == "Local" }

    // --- Modern Permission Handling ---
    val context = LocalContext.current
    var pendingAction by remember { mutableStateOf<(() -> Unit)?>(null) }

    val permission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        android.Manifest.permission.READ_MEDIA_AUDIO
    } else {
        android.Manifest.permission.READ_EXTERNAL_STORAGE
    }

    val launcher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { isGranted: Boolean ->
        if (isGranted) {
            pendingAction?.invoke()
            pendingAction = null
        }
    }

    val requestPermissionAndExecute: (() -> Unit) -> Unit = { action ->
        when (ContextCompat.checkSelfPermission(context, permission)) {
            PackageManager.PERMISSION_GRANTED -> {
                action()
            }
            else -> {
                pendingAction = action
                launcher.launch(permission)
            }
        }
    }
    // --- End Permission Handling ---


    Scaffold(
        floatingActionButton = {
            FloatingActionButton(onClick = {
                profileToEdit = null
                showDialog = true
            }) {
                Icon(Icons.Default.Add, contentDescription = "Add Profile")
            }
        }
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 16.dp),
            contentPadding = PaddingValues(
                top = 16.dp,
                bottom = padding.calculateBottomPadding() + 16.dp
            ),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            items(uiState.profiles) { profile ->
                ProfileItem(
                    profile = profile,
                    isError = uiState.connectionErrorProfileId == profile.id,
                    isSyncing = uiState.syncingProfileId == profile.id,
                    syncStatus = if (uiState.lastSyncProfileId == profile.id) uiState.lastSyncStatus else SyncStatus.IDLE,
                    onClick = {
                        if (it.name == "Local") {
                            // Request permission before setting active
                            requestPermissionAndExecute { viewModel.setActiveProfile(it) }
                        } else {
                            viewModel.setActiveProfile(it)
                        }
                    },
                    onEdit = {
                        profileToEdit = it
                        showDialog = true
                    },
                    onDelete = {
                        showDeleteConfirmation = it
                    },
                    onSync = {
                        if (it.name == "Local") {
                            // Request permission before syncing
                            requestPermissionAndExecute { viewModel.syncLibrary(it) }
                        } else {
                            viewModel.syncLibrary(it)
                        }
                    }
                )
            }
            if (!localProfileExists) {
                item {
                    Button(
                        onClick = {
                            // Request permission before creating
                            requestPermissionAndExecute { viewModel.createLocalProfile() }
                        },
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(top = 8.dp)
                    ) {
                        Text("Use Local Music")
                    }
                }
            }
        }
    }

    if (showDialog) {
        ProfileEditDialog(
            profile = profileToEdit,
            onDismiss = { showDialog = false },
            onSave = { name, host, port ->
                if (profileToEdit == null) {
                    viewModel.addProfile(name, host, port)
                } else {
                    viewModel.updateProfile(profileToEdit!!.copy(name = name, host = host, port = port))
                }
                showDialog = false
            }
        )
    }

    showDeleteConfirmation?.let { profile ->
        AlertDialog(
            onDismissRequest = { showDeleteConfirmation = null },
            title = { Text("Delete Profile") },
            text = { Text("Are you sure you want to delete profile '${profile.name}'?") },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.deleteProfile(profile)
                        showDeleteConfirmation = null
                    }
                ) {
                    Text("Delete")
                }
            },
            dismissButton = {
                TextButton(onClick = { showDeleteConfirmation = null }) {
                    Text("Cancel")
                }
            }
        )
    }
}

@Composable
fun ProfileItem(
    profile: Profile,
    isError: Boolean,
    isSyncing: Boolean,
    syncStatus: SyncStatus,
    onClick: (Profile) -> Unit,
    onEdit: (Profile) -> Unit,
    onDelete: (Profile) -> Unit,
    onSync: (Profile) -> Unit,
    modifier: Modifier = Modifier
) {
    val isLocalProfile = profile.name == "Local"
    val containerColor = when {
        isError -> MaterialTheme.colorScheme.errorContainer
        profile.isActive -> MaterialTheme.colorScheme.primaryContainer
        else -> MaterialTheme.colorScheme.surfaceVariant
    }

    Card(
        modifier = modifier
            .fillMaxWidth()
            .clickable { onClick(profile) },
        colors = CardDefaults.cardColors(containerColor = containerColor),
        elevation = CardDefaults.cardElevation(defaultElevation = 2.dp)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(text = profile.name)
                if (!isLocalProfile) {
                    Text(text = "${profile.host}:${profile.port}")
                }
                if (isError) {
                    Text(
                        text = "Cannot connect to this server",
                        color = MaterialTheme.colorScheme.error,
                        style = MaterialTheme.typography.bodySmall
                    )
                }
                when {
                    isSyncing -> {
                        Text(
                            text = "Syncing...",
                            style = MaterialTheme.typography.bodySmall
                        )
                    }

                    syncStatus == SyncStatus.SUCCESS -> {
                        Text(
                            text = "Sync complete",
                            color = MaterialTheme.colorScheme.primary,
                            style = MaterialTheme.typography.bodySmall
                        )
                    }

                    syncStatus == SyncStatus.FAILED -> {
                        Text(
                            text = "Sync failed",
                            color = MaterialTheme.colorScheme.error,
                            style = MaterialTheme.typography.bodySmall
                        )
                    }
                }
            }
            Spacer(modifier = Modifier.width(16.dp))

            // Show sync button for active profiles.
            // For remote profiles, hide it if there's a connection error.
            if (profile.isActive && (isLocalProfile || !isError)) {
                Box(
                    modifier = Modifier.size(48.dp),
                    contentAlignment = Alignment.Center
                ) {
                    if (isSyncing) {
                        CircularProgressIndicator(modifier = Modifier.size(24.dp))
                    } else {
                        IconButton(onClick = { onSync(profile) }) {
                            Icon(Icons.Default.Sync, contentDescription = "Sync Library")
                        }
                    }
                }
            }

            if (!isLocalProfile) {
                IconButton(onClick = { onEdit(profile) }) {
                    Icon(Icons.Default.Edit, contentDescription = "Edit Profile")
                }
            }
            IconButton(onClick = { onDelete(profile) }) {
                Icon(Icons.Default.Delete, contentDescription = "Delete Profile")
            }
        }
    }
}

@Composable
fun ProfileEditDialog(
    profile: Profile?,
    onDismiss: () -> Unit,
    onSave: (String, String, Int) -> Unit
) {
    var name by remember { mutableStateOf(profile?.name ?: "") }
    // Corrected line below
    var host by remember { mutableStateOf(profile?.host ?: "") }
    var port by remember { mutableStateOf(profile?.port?.toString() ?: "6600") }

    Dialog(onDismissRequest = onDismiss) {
        Card {
            Column(modifier = Modifier.padding(16.dp)) {
                Text(text = if (profile == null) "Add Profile" else "Edit Profile")
                Spacer(modifier = Modifier.padding(8.dp))
                TextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text("Profile Name") }
                )
                Spacer(modifier = Modifier.padding(8.dp))
                TextField(
                    value = host,
                    onValueChange = { host = it },
                    label = { Text("Host") }
                )
                Spacer(modifier = Modifier.padding(8.dp))
                TextField(
                    value = port,
                    onValueChange = { port = it },
                    label = { Text("Port") }
                )
                Spacer(modifier = Modifier.padding(16.dp))
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.End
                ) {
                    TextButton(onClick = onDismiss) {
                        Text("Cancel")
                    }
                    Spacer(modifier = Modifier.width(8.dp))
                    Button(onClick = { onSave(name, host, port.toIntOrNull() ?: 6600) }) {
                        Text("Save")
                    }
                }
            }
        }
    }
}
