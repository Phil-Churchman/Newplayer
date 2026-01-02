package com.example.newplayer

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Album
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.example.newplayer.data.*
import com.example.newplayer.ui.theme.NewPlayerTheme
import kotlinx.coroutines.launch
import com.example.newplayer.data.Album
import com.example.newplayer.data.Artist
import com.example.newplayer.data.Song



sealed class Screen(val route: String, val title: String, val icon: ImageVector) {
    object Songs : Screen("songs", "Songs", Icons.Default.MusicNote)
    object Artists : Screen("artists", "Artists", Icons.Default.Person)
    object Albums : Screen("albums", "Albums", Icons.Default.Album)
}

val navigationItems = listOf(
    Screen.Songs,
    Screen.Artists,
    Screen.Albums
)

class MainActivity : ComponentActivity() {

    private lateinit var database: AppDatabase
    private lateinit var repository: LocalSongRepository
    private var isScanning by mutableStateOf(false)

    private val requestPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { isGranted: Boolean ->
        if (isGranted) {
            scanSongs()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        database = AppDatabase.getDatabase(this)
        repository = LocalSongRepository(this, database.songDao(), database.artistDao(), database.albumDao())

        setContent {
            NewPlayerTheme {
                AppRoot(
                    repository = repository,
                    isScanning = isScanning,
                    onScanSongs = { checkAndRequestPermission() }
                )
            }
        }
    }

    private fun checkAndRequestPermission() {
        val permission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.READ_MEDIA_AUDIO
        } else {
            Manifest.permission.READ_EXTERNAL_STORAGE
        }

        when (ContextCompat.checkSelfPermission(this, permission)) {
            PackageManager.PERMISSION_GRANTED -> {
                scanSongs()
            }
            else -> {
                requestPermissionLauncher.launch(permission)
            }
        }
    }

    private fun scanSongs() {
        lifecycleScope.launch {
            isScanning = true
            repository.scanForSongs()
            isScanning = false
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AppRoot(
    repository: LocalSongRepository,
    isScanning: Boolean,
    onScanSongs: () -> Unit
) {
    val navController = rememberNavController()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Local Music") },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.primaryContainer,
                    titleContentColor = MaterialTheme.colorScheme.primary,
                )
            )
        },
        bottomBar = {
            NavigationBar {
                val navBackStackEntry by navController.currentBackStackEntryAsState()
                val currentDestination = navBackStackEntry?.destination
                navigationItems.forEach { screen ->
                    NavigationBarItem(
                        icon = { Icon(screen.icon, contentDescription = null) },
                        label = { Text(screen.title) },
                        selected = currentDestination?.hierarchy?.any { it.route == screen.route } == true,
                        onClick = {
                            navController.navigate(screen.route) {
                                popUpTo(navController.graph.findStartDestination().id) {
                                    saveState = true
                                }
                                launchSingleTop = true
                                restoreState = true
                            }
                        }
                    )
                }
            }
        },
        floatingActionButton = {
            FloatingActionButton(onClick = { if (!isScanning) onScanSongs() }) {
                if (isScanning) {
                    CircularProgressIndicator(modifier = Modifier.size(28.dp))
                } else {
                    Icon(Icons.Default.Search, contentDescription = "Scan for songs")
                }
            }
        }
    ) { innerPadding ->
        NavHost(navController, startDestination = Screen.Songs.route, Modifier.padding(innerPadding)) {
            composable(Screen.Songs.route) {
                SongListScreen(repository, isScanning)
            }
            composable(Screen.Artists.route) {
                ArtistListScreen(repository)
            }
            composable(Screen.Albums.route) {
                AlbumListScreen(repository)
            }
        }
    }
}

@Composable
fun SongListScreen(
    repository: LocalSongRepository,
    isScanning: Boolean,
    modifier: Modifier = Modifier
) {
    val songs by repository.allSongs.collectAsState(initial = emptyList())

    Box(modifier = modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        if (isScanning) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                CircularProgressIndicator()
                Spacer(modifier = Modifier.height(8.dp))
                Text("Scanning for music...")
            }
        } else if (songs.isEmpty()) {
            Text("No songs found. Tap the scan button to find music.")
        } else {
            LazyColumn(modifier = Modifier.fillMaxSize()) {
                items(songs) { song ->
                    SongListItem(song)
                }
            }
        }
    }
}

@Composable
fun ArtistListScreen(repository: LocalSongRepository, modifier: Modifier = Modifier) {
    val artists by repository.allArtists.collectAsState(initial = emptyList())
    LazyColumn(modifier = modifier.fillMaxSize()) {
        items(artists) { artist ->
            ListItem(headlineContent = { Text(artist.name) })
        }
    }
}

@Composable
fun AlbumListScreen(repository: LocalSongRepository, modifier: Modifier = Modifier) {
    val albums by repository.allAlbums.collectAsState(initial = emptyList())
    LazyColumn(modifier = modifier.fillMaxSize()) {
        items(albums) { album ->
            ListItem(headlineContent = { Text(album.name) })
        }
    }
}

@Composable
fun SongListItem(song: Song) {
    ListItem(
        headlineContent = { Text(song.title) },
        supportingContent = { Text(song.artist) }
    )
}
