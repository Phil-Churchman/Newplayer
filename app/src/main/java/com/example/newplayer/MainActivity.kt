package com.example.newplayer

import android.Manifest
import android.content.ComponentName
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Album
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PauseCircleFilled
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.PlayCircleFilled
import androidx.compose.material.icons.filled.QueueMusic
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.common.Timeline
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import coil.compose.AsyncImage
import com.example.newplayer.data.AppDatabase
import com.example.newplayer.data.LocalSongRepository
import com.example.newplayer.data.Song
import com.example.newplayer.ui.theme.NewPlayerTheme
import com.google.common.util.concurrent.MoreExecutors
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch


sealed class Screen(val route: String, val title: String, val icon: ImageVector) {
    data object Songs : Screen("songs", "Songs", Icons.Default.MusicNote)
    data object Artists : Screen("artists", "Artists", Icons.Default.Person)
    data object Albums : Screen("albums", "Albums", Icons.Default.Album)
    data object Queue : Screen("queue", "Queue", Icons.Default.QueueMusic)
}

val navigationItems = listOf(
    Screen.Songs,
    Screen.Artists,
    Screen.Albums,
    Screen.Queue,
)

class MainActivity : ComponentActivity() {

    private lateinit var database: AppDatabase
    private lateinit var repository: LocalSongRepository
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        database = AppDatabase.getDatabase(applicationContext)
        repository = LocalSongRepository(this,
            database.songDao(), database.artistDao(), database.albumDao()
        )
        setContent {
            NewPlayerTheme {
                var isScanning by remember { mutableStateOf(false) }
                val scope = rememberCoroutineScope()
                val context = LocalContext.current
                var mediaController by remember { mutableStateOf<MediaController?>(null) }

                val songs by repository.allSongs.collectAsState(initial = emptyList())
                val mediaItems = remember(songs) {
                    songs.map { song ->
                        val metadata = MediaMetadata.Builder()
                            .setTitle(song.title)
                            .setArtist(song.artist)
                            .build()
                        MediaItem.Builder()
                            .setMediaId(song.id.toString())
                            .setUri(song.path)
                            .setMediaMetadata(metadata)
                            .build()
                    }
                }

                val permissionLauncher = rememberLauncherForActivityResult(
                    contract = ActivityResultContracts.RequestPermission(),
                    onResult = { isGranted: Boolean ->
                        if (isGranted) {
                            scope.launch {
                                isScanning = true
                                repository.scanForSongs()
                                isScanning = false
                            }
                        }
                    }
                )

                val scanAction = {
                    if (context.checkSelfPermission(Manifest.permission.READ_MEDIA_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                        scope.launch {
                            isScanning = true
                            repository.scanForSongs()
                            isScanning = false
                        }
                    } else {
                        permissionLauncher.launch(Manifest.permission.READ_MEDIA_AUDIO)
                    }
                }

                DisposableEffect(context) {
                    val sessionToken = SessionToken(context, ComponentName(context, PlaybackService::class.java))
                    val controllerFuture = MediaController.Builder(context, sessionToken).buildAsync()
                    controllerFuture.addListener(
                        {
                            mediaController = controllerFuture.get()
                        },
                        MoreExecutors.directExecutor()
                    )

                    onDispose {
                        mediaController?.release()
                    }
                }

                LaunchedEffect(Unit) {
                    scope.launch {
                        val songsCount = repository.allSongs.first().size
                        if (songsCount == 0) {
                            scanAction()
                        }
                    }
                }

                AppRoot(
                    repository = repository,
                    isScanning = isScanning,
                    onScanSongs = {
                        scanAction()
                    },
                    mediaController = mediaController,
                    mediaItems = mediaItems
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AppRoot(
    repository: LocalSongRepository,
    isScanning: Boolean,
    onScanSongs: () -> Unit,
    mediaController: MediaController?,
    mediaItems: List<MediaItem>
) {
    val navController = rememberNavController()
    val songs by repository.allSongs.collectAsState(initial = emptyList())
    var showMenu by remember { mutableStateOf(false) }

    val navBackStackEntry by navController.currentBackStackEntryAsState()
    val currentDestination = navBackStackEntry?.destination

    val currentScreen = navigationItems.find { it.route == currentDestination?.route }
    val isPlayerScreen = currentDestination?.route == "player"

    Scaffold(
        topBar = {
            if (currentScreen != null) {
                TopAppBar(
                    title = { Text(currentScreen.title) },
                    colors = TopAppBarDefaults.topAppBarColors(
                        containerColor = MaterialTheme.colorScheme.primaryContainer,
                        titleContentColor = MaterialTheme.colorScheme.primary,
                    ),
                    actions = {
                        if (songs.isNotEmpty()) {
                            IconButton(onClick = { showMenu = !showMenu }) {
                                Icon(
                                    imageVector = Icons.Default.MoreVert,
                                    contentDescription = "More options"
                                )
                            }
                            DropdownMenu(
                                expanded = showMenu,
                                onDismissRequest = { showMenu = false }
                            ) {
                                DropdownMenuItem(
                                    text = { Text("Sync") },
                                    onClick = {
                                        showMenu = false
                                        onScanSongs()
                                    }
                                )
                            }
                        }
                    }
                )
            }
        },
        bottomBar = {
            if (!isPlayerScreen) {
                Column {
                    mediaController?.let { controller ->
                        MiniPlayer(
                            repository = repository,
                            mediaController = controller,
                            onClick = { navController.navigate("player") }
                        )
                    }
                    NavigationBar {
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
                }
            }
        },
        floatingActionButton = {
            if (songs.isEmpty() && !isPlayerScreen) {
                FloatingActionButton(onClick = { if (!isScanning) onScanSongs() }) {
                    if (isScanning) {
                        CircularProgressIndicator(modifier = Modifier.size(28.dp))
                    } else {
                        Icon(Icons.Default.Search, contentDescription = "Scan for songs")
                    }
                }
            }
        }
    ) { innerPadding ->
        NavHost(navController, startDestination = Screen.Songs.route, modifier = Modifier.padding(innerPadding)) {
            composable(Screen.Songs.route) {
                SongListScreen(
                    repository = repository,
                    isScanning = isScanning,
                    mediaController = mediaController,
                    mediaItems = mediaItems
                )
            }
            composable(Screen.Artists.route) {
                ArtistListScreen(repository, navController)
            }
            composable(Screen.Albums.route) {
                AlbumListScreen(repository, navController)
            }
            composable(Screen.Queue.route) {
                QueueScreen(repository = repository, mediaController = mediaController)
            }
            composable("player") {
                FullScreenPlayer(
                    repository = repository,
                    mediaController = mediaController,
                    onBack = { navController.popBackStack() }
                )
            }
            composable(
                "artist_albums/{artistId}",
                arguments = listOf(navArgument("artistId") { type = NavType.LongType })
            ) { backStackEntry ->
                val artistId = backStackEntry.arguments?.getLong("artistId")
                if (artistId != null) {
                    ArtistAlbumListScreen(repository, artistId, navController, onBack = { navController.popBackStack() })
                }
            }
            composable(
                "album_songs/{albumId}",
                arguments = listOf(navArgument("albumId") { type = NavType.LongType })
            ) { backStackEntry ->
                val albumId = backStackEntry.arguments?.getLong("albumId")
                if (albumId != null) {
                    AlbumSongListScreen(repository, albumId, onBack = { navController.popBackStack() }, mediaController, mediaItems)
                }
            }
        }
    }
}

@Composable
fun MiniPlayer(repository: LocalSongRepository, mediaController: MediaController, onClick: () -> Unit) {
    var currentMediaItem by remember { mutableStateOf(mediaController.currentMediaItem) }
    var isPlaying by remember { mutableStateOf(mediaController.isPlaying) }

    val songs by repository.allSongs.collectAsState(initial = emptyList())
    val albums by repository.allAlbums.collectAsState(initial = emptyList())

    val song = songs.find { it.id.toString() == currentMediaItem?.mediaId }
    val album = if (song != null) albums.find { it.id == song.albumId } else null
    val artwork = album?.artwork

    DisposableEffect(mediaController) {
        val listener = object : Player.Listener {
            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                currentMediaItem = mediaItem
            }

            override fun onIsPlayingChanged(playing: Boolean) {
                isPlaying = playing
            }
        }
        mediaController.addListener(listener)
        onDispose {
            mediaController.removeListener(listener)
        }
    }

    if (currentMediaItem == null) {
        // Don't show the player if there's nothing in the queue
        return
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .clickable(onClick = onClick)
            .padding(8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        AsyncImage(
            model = artwork,
            contentDescription = "Album artwork",
            modifier = Modifier
                .size(48.dp)
                .clip(RoundedCornerShape(4.dp)),
            contentScale = ContentScale.Crop
        )
        Spacer(modifier = Modifier.width(8.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = currentMediaItem?.mediaMetadata?.title?.toString() ?: "Unknown Title",
                style = MaterialTheme.typography.titleMedium
            )
            Text(
                text = currentMediaItem?.mediaMetadata?.artist?.toString() ?: "Unknown Artist",
                style = MaterialTheme.typography.bodySmall
            )
        }
        Row {
            IconButton(onClick = {
                if (isPlaying) {
                    mediaController.pause()
                } else {
                    mediaController.play()
                }
            }) {
                Icon(
                    if (isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow,
                    contentDescription = "Play/Pause"
                )
            }
            IconButton(onClick = { mediaController.seekToNextMediaItem() }) {
                Icon(Icons.Default.SkipNext, contentDescription = "Skip Next")
            }
        }
    }
}

@Composable
fun QueueScreen(repository: LocalSongRepository, mediaController: MediaController?, modifier: Modifier = Modifier) {
    if (mediaController == null) {
        Box(modifier = modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text("Queue not available")
        }
        return
    }

    val songs by repository.allSongs.collectAsState(initial = emptyList())
    val albums by repository.allAlbums.collectAsState(initial = emptyList())
    var timeline by remember { mutableStateOf(mediaController.currentTimeline) }
    var currentMediaItem by remember { mutableStateOf(mediaController.currentMediaItem) }

    DisposableEffect(mediaController) {
        val listener = object : Player.Listener {
            override fun onEvents(player: Player, events: Player.Events) {
                timeline = player.currentTimeline
                currentMediaItem = player.currentMediaItem
            }
        }

        mediaController.addListener(listener)

        timeline = mediaController.currentTimeline
        currentMediaItem = mediaController.currentMediaItem

        onDispose {
            mediaController.removeListener(listener)
        }
    }

    val mediaItems = remember(timeline) {
        if (timeline.isEmpty) {
            emptyList()
        } else {
            (0 until timeline.windowCount).map { i ->
                val window = Timeline.Window()
                timeline.getWindow(i, window)
                window.mediaItem
            }
        }
    }

    if (mediaItems.isEmpty()) {
        Box(modifier = modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text("Queue is empty")
        }
        return
    }

    LazyColumn(modifier = modifier) {
        itemsIndexed(
            items = mediaItems,
            key = { _, item -> item.mediaId }
        ) { index, item ->
            val isCurrentlyPlaying = item.mediaId == currentMediaItem?.mediaId
            val song = songs.find { it.id.toString() == item.mediaId }
            val album = if (song != null) albums.find { it.id == song.albumId } else null

            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(if (isCurrentlyPlaying) MaterialTheme.colorScheme.primaryContainer else Color.Transparent)
                    .clickable {
                        if (!isCurrentlyPlaying) {
                            mediaController.seekTo(index, 0)
                        }
                        mediaController.play()
                    }
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                AsyncImage(
                    model = album?.artwork,
                    contentDescription = "Album artwork",
                    modifier = Modifier
                        .size(40.dp)
                        .clip(RoundedCornerShape(4.dp)),
                    contentScale = ContentScale.Crop
                )
                Spacer(modifier = Modifier.width(16.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = item.mediaMetadata.title?.toString() ?: "Unknown Title",
                        fontWeight = if (isCurrentlyPlaying) FontWeight.Bold else FontWeight.Normal,
                        style = MaterialTheme.typography.bodyLarge
                    )
                    Spacer(modifier = Modifier.height(4.dp))
                    Text(
                        text = item.mediaMetadata.artist?.toString() ?: "Unknown Artist",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                IconButton(onClick = {
                    val isRemovingCurrent = mediaController.currentMediaItemIndex == index
                    mediaController.removeMediaItem(index)
                    if (isRemovingCurrent && mediaController.mediaItemCount > 0) {
                        mediaController.seekToDefaultPosition(0)
                        mediaController.play()
                    }
                }) {
                    Icon(Icons.Default.Delete, contentDescription = "Remove from queue")
                }
            }
        }
    }
}

@Composable
fun SongListScreen(
    repository: LocalSongRepository,
    isScanning: Boolean,
    modifier: Modifier = Modifier,
    mediaController: MediaController?,
    mediaItems: List<MediaItem>
) {
    val songs by repository.allSongs.collectAsState(initial = emptyList())
    val sortedSongs = songs.sortedBy { it.title }
    val albums by repository.allAlbums.collectAsState(initial = emptyList())

    Box(modifier = modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        if (isScanning && songs.isEmpty()) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                CircularProgressIndicator()
                Spacer(modifier = Modifier.height(8.dp))
                Text("Scanning for music...")
            }
        } else {
            FastScrollLazyColumn(
                modifier = Modifier.fillMaxSize(),
                items = sortedSongs,
                itemContent = { song ->
                    val album = albums.find { it.id == song.albumId }
                    SongListItem(song, album?.artwork) {
                        mediaController?.let { controller ->
                            val mediaItem = mediaItems.find { it.mediaId == song.id.toString() }
                            if (mediaItem != null) {
                                val newItemIndex = controller.mediaItemCount
                                controller.addMediaItem(mediaItem)
                                controller.seekTo(newItemIndex, 0L)
                                controller.prepare()
                                controller.play()
                            }
                        }
                    }
                },
                indicatorContent = { song -> song.title.firstOrNull()?.uppercase() ?: "#" },
                emptyContent = {
                    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Text("No songs found. Tap the scan button to find music.")
                    }
                }
            )
        }
    }
}

@Composable
fun ArtistListScreen(repository: LocalSongRepository, navController: NavHostController, modifier: Modifier = Modifier) {
    val artistsWithArtwork by repository.artistsWithArtwork.collectAsState(initial = emptyList())

    FastScrollLazyColumn(
        modifier = modifier.fillMaxSize(),
        items = artistsWithArtwork,
        itemContent = { artist ->
            ListItem(
                headlineContent = { Text(artist.artistName) },
                leadingContent = {
                    AsyncImage(
                        model = artist.artwork,
                        contentDescription = "Artist artwork",
                        modifier = Modifier
                            .size(40.dp)
                            .clip(RoundedCornerShape(4.dp)),
                        contentScale = ContentScale.Crop
                    )
                },
                modifier = Modifier.clickable { navController.navigate("artist_albums/${artist.artistId}") }
            )
        },
        indicatorContent = { artist -> artist.artistName.firstOrNull()?.uppercase() ?: "#" },
        emptyContent = {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("No artists found.")
            }
        }
    )
}

@Composable
fun AlbumListScreen(repository: LocalSongRepository, navController: NavHostController, modifier: Modifier = Modifier) {
    val albums by repository.allAlbums.collectAsState(initial = emptyList())
    val sortedAlbums = albums.sortedBy { it.name }

    FastScrollLazyColumn(
        modifier = modifier.fillMaxSize(),
        items = sortedAlbums,
        itemContent = { album ->
            ListItem(
                headlineContent = { Text(album.name) },
                leadingContent = {
                    AsyncImage(
                        model = album.artwork,
                        contentDescription = "Album artwork",
                        modifier = Modifier
                            .size(40.dp)
                            .clip(RoundedCornerShape(4.dp)),
                        contentScale = ContentScale.Crop
                    )
                },
                modifier = Modifier.clickable { navController.navigate("album_songs/${album.id}") }
            )
        },
        indicatorContent = { album -> album.name.firstOrNull()?.uppercase() ?: "#" },
        emptyContent = {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("No albums found.")
            }
        }
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ArtistAlbumListScreen(
    repository: LocalSongRepository,
    artistId: Long,
    navController: NavHostController,
    onBack: () -> Unit
) {
    val artistName by repository.getArtistNameById(artistId).collectAsState(initial = "Albums")
    val albums by repository.getAlbumsByArtistId(artistId).collectAsState(initial = emptyList())

    Scaffold(
        contentWindowInsets = WindowInsets(0.dp),
        topBar = {
            TopAppBar(
                title = { Text(artistName ?: "Albums") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.primaryContainer,
                    titleContentColor = MaterialTheme.colorScheme.primary,
                )
            )
        }
    ) { innerPadding ->
        FastScrollLazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding),
            items = albums,
            itemContent = { album ->
                ListItem(
                    headlineContent = { Text(album.name) },
                    leadingContent = {
                        AsyncImage(
                            model = album.artwork,
                            contentDescription = "Album artwork",
                            modifier = Modifier
                                .size(40.dp)
                                .clip(RoundedCornerShape(4.dp)),
                            contentScale = ContentScale.Crop
                        )
                    },
                    modifier = Modifier.clickable { navController.navigate("album_songs/${album.id}") }
                )
            },
            indicatorContent = { album -> album.name.firstOrNull()?.uppercase() ?: "#" },
            emptyContent = {
                Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text("No albums found for this artist.")
                }
            }
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AlbumSongListScreen(
    repository: LocalSongRepository,
    albumId: Long,
    onBack: () -> Unit,
    mediaController: MediaController?,
    mediaItems: List<MediaItem>
) {
    val album by repository.getAlbumById(albumId).collectAsState(initial = null)
    val songs by repository.getSongsByAlbumId(albumId).collectAsState(initial = emptyList())

    Scaffold(
        contentWindowInsets = WindowInsets(0.dp),
        topBar = {
            TopAppBar(
                title = { Text(album?.name ?: "Songs") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back")
                    }
                },
                actions = {
                    if (songs.isNotEmpty()) {
                        IconButton(onClick = {
                            mediaController?.let { controller ->
                                val albumMediaItems = mediaItems.filter { mediaItem -> songs.any { it.id.toString() == mediaItem.mediaId } }
                                if (albumMediaItems.isNotEmpty()) {
                                    controller.setMediaItems(albumMediaItems, 0, 0)
                                    controller.prepare()
                                    controller.play()
                                }
                            }
                        }) {
                            Icon(Icons.Default.PlayArrow, contentDescription = "Play album")
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.primaryContainer,
                    titleContentColor = MaterialTheme.colorScheme.primary,
                )
            )
        }
    ) { innerPadding ->
        Column(modifier = Modifier
            .padding(innerPadding)
        ) {
            AsyncImage(
                model = album?.artwork,
                contentDescription = "Album artwork",
                modifier = Modifier
                    .fillMaxWidth()
                    .height(200.dp),
                contentScale = ContentScale.Crop
            )
            LazyColumn(modifier = Modifier.weight(1f)) {
                if (songs.isEmpty()) {
                    item {
                        Box(
                            modifier = Modifier.fillParentMaxSize(),
                            contentAlignment = Alignment.Center
                        ) {
                            Text("No songs found for this album.")
                        }
                    }
                } else {
                    items(songs) { song ->
                        ListItem(
                            headlineContent = { Text(song.title) },
                            supportingContent = { Text(song.artist) },
                            leadingContent = {
                                Box(
                                    modifier = Modifier.width(24.dp),
                                    contentAlignment = Alignment.Center
                                ) {
                                    Text(song.track.toString())
                                }
                            },
                            modifier = Modifier.clickable {
                                mediaController?.let { controller ->
                                    val mediaItem = mediaItems.find { it.mediaId == song.id.toString() }
                                    if (mediaItem != null) {
                                        val newItemIndex = controller.mediaItemCount
                                        controller.addMediaItem(mediaItem)
                                        controller.seekTo(newItemIndex, 0L)
                                        controller.prepare()
                                        controller.play()
                                    }
                                }
                            }
                        )
                    }
                }
            }
        }
    }
}

fun formatDuration(ms: Long): String {
    val totalSeconds = ms / 1000
    val minutes = totalSeconds / 60
    val seconds = totalSeconds % 60
    return String.format("%02d:%02d", minutes, seconds)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FullScreenPlayer(
    repository: LocalSongRepository,
    mediaController: MediaController?,
    onBack: () -> Unit
) {
    if (mediaController == null) {
        Scaffold { padding ->
            Box(modifier = Modifier.padding(padding).fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("Player not available")
            }
        }
        return
    }

    var currentMediaItem by remember { mutableStateOf(mediaController.currentMediaItem) }
    var isPlaying by remember { mutableStateOf(mediaController.isPlaying) }
    var currentPosition by remember { mutableStateOf(mediaController.currentPosition) }
    var duration by remember { mutableStateOf(mediaController.duration) }
    var isSeeking by remember { mutableStateOf(false) }
    var seekPosition by remember { mutableStateOf(0L) }

    DisposableEffect(mediaController) {
        val listener = object : Player.Listener {
            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                currentMediaItem = mediaItem
            }
            override fun onIsPlayingChanged(playing: Boolean) {
                isPlaying = playing
            }
            override fun onPositionDiscontinuity(oldPosition: Player.PositionInfo, newPosition: Player.PositionInfo, reason: Int) {
                currentPosition = newPosition.positionMs
            }
        }
        mediaController.addListener(listener)
        currentMediaItem = mediaController.currentMediaItem
        isPlaying = mediaController.isPlaying
        currentPosition = mediaController.currentPosition
        duration = mediaController.duration
        onDispose {
            mediaController.removeListener(listener)
        }
    }

    LaunchedEffect(isPlaying) {
        if (isPlaying) {
            while (true) {
                if (!isSeeking) {
                    currentPosition = mediaController.currentPosition
                    duration = mediaController.duration
                }
                delay(1000)
            }
        }
    }

    val songs by repository.allSongs.collectAsState(initial = emptyList())
    val albums by repository.allAlbums.collectAsState(initial = emptyList())
    val song = songs.find { it.id.toString() == currentMediaItem?.mediaId }
    val album = if (song != null) albums.find { it.id == song.albumId } else null
    val artwork = album?.artwork

    Scaffold(
        topBar = {
            TopAppBar(
                title = { },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent)
            )
        },
        contentWindowInsets = WindowInsets(0.dp)
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .padding(innerPadding)
                .fillMaxSize()
                .padding(horizontal = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            AsyncImage(
                model = artwork,
                contentDescription = "Album Artwork",
                modifier = Modifier
                    .fillMaxWidth()
                    .aspectRatio(1f)
                    .clip(RoundedCornerShape(12.dp)),
                contentScale = ContentScale.Crop
            )

            Spacer(modifier = Modifier.height(32.dp))

            Text(
                text = currentMediaItem?.mediaMetadata?.title?.toString() ?: "Unknown Title",
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.Bold,
                maxLines = 1
            )
            Text(
                text = currentMediaItem?.mediaMetadata?.artist?.toString() ?: "Unknown Artist",
                style = MaterialTheme.typography.titleMedium,
                maxLines = 1
            )

            Spacer(modifier = Modifier.height(16.dp))

            Column {
                Slider(
                    value = if (isSeeking) seekPosition.toFloat() else currentPosition.toFloat(),
                    onValueChange = {
                        isSeeking = true
                        seekPosition = it.toLong()
                    },
                    valueRange = 0f..(duration.toFloat().coerceAtLeast(0f)),
                    onValueChangeFinished = {
                        mediaController.seekTo(seekPosition)
                        isSeeking = false
                    }
                )
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(text = formatDuration(if (isSeeking) seekPosition else currentPosition))
                    Text(text = formatDuration(duration))
                }
            }

            Spacer(modifier = Modifier.height(16.dp))

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceEvenly,
                verticalAlignment = Alignment.CenterVertically
            ) {
                IconButton(onClick = { mediaController.seekToPreviousMediaItem() }) {
                    Icon(Icons.Default.SkipPrevious, contentDescription = "Previous", modifier = Modifier.size(48.dp))
                }
                IconButton(onClick = { if (isPlaying) mediaController.pause() else mediaController.play() }) {
                    Icon(
                        if (isPlaying) Icons.Default.PauseCircleFilled else Icons.Default.PlayCircleFilled,
                        contentDescription = "Play/Pause",
                        modifier = Modifier.size(72.dp)
                    )
                }
                IconButton(onClick = { mediaController.seekToNextMediaItem() }) {
                    Icon(Icons.Default.SkipNext, contentDescription = "Next", modifier = Modifier.size(48.dp))
                }
            }
        }
    }
}


@Composable
fun SongListItem(song: Song, artwork: ByteArray?, onClick: () -> Unit) {
    ListItem(
        headlineContent = { Text(song.title) },
        supportingContent = { Text(song.artist) },
        leadingContent = {
            AsyncImage(
                model = artwork,
                contentDescription = "Album artwork",
                modifier = Modifier
                    .size(40.dp)
                    .clip(RoundedCornerShape(4.dp)),
                contentScale = ContentScale.Crop
            )
        },
        modifier = Modifier.clickable(onClick = onClick)
    )
}

@Composable
private fun <T> FastScrollLazyColumn(
    modifier: Modifier = Modifier,
    items: List<T>,
    itemContent: @Composable (T) -> Unit,
    indicatorContent: (T) -> String,
    emptyContent: @Composable () -> Unit
) {
    if (items.isEmpty()) {
        emptyContent()
        return
    }

    val listState = rememberLazyListState()
    val scope = rememberCoroutineScope()
var isDragging by remember { mutableStateOf(false) }

    Box(modifier = modifier) {
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize()
        ) {
            items(items) { item ->
                itemContent(item)
            }
        }

        BoxWithConstraints(
            modifier = Modifier
                .align(Alignment.CenterEnd)
                .fillMaxHeight()
                .width(24.dp)
                .pointerInput(Unit) {
                    detectVerticalDragGestures(
                        onDragStart = { isDragging = true },
                        onDragEnd = { isDragging = false },
                        onVerticalDrag = { change, _ ->
                            scope.launch {
                                val dragRatio = (change.position.y / size.height).coerceIn(0f, 1f)
                                val index = (dragRatio * (items.size - 1)).toInt()
                                listState.scrollToItem(index)
                            }
                        }
                    )
                }
        ) {
            val visibleItemsInfo = listState.layoutInfo.visibleItemsInfo
            val totalItemsCount = listState.layoutInfo.totalItemsCount
            if (visibleItemsInfo.isNotEmpty() && totalItemsCount > visibleItemsInfo.size) {

                val containerHeight = this.maxHeight
                val visibleItemsRatio = visibleItemsInfo.size.toFloat() / totalItemsCount
                val thumbHeight = (containerHeight * visibleItemsRatio).coerceAtLeast(24.dp)

                val scrollableRange = containerHeight - thumbHeight
                val scrollProgress = listState.firstVisibleItemIndex.toFloat() / (totalItemsCount - visibleItemsInfo.size).toFloat()

                val thumbOffset = (scrollableRange * scrollProgress).coerceIn(0.dp, containerHeight - thumbHeight)

                Box(
                    modifier = Modifier
                        .align(Alignment.TopCenter)
                        .offset(y = thumbOffset)
                        .height(thumbHeight)
                        .width(4.dp)
                        .background(color = MaterialTheme.colorScheme.primary, shape = RoundedCornerShape(2.dp))
                )
            }
        }

        val firstVisibleItem = items.getOrNull(listState.firstVisibleItemIndex)
        if (isDragging && firstVisibleItem != null) {
            val indicatorChar = indicatorContent(firstVisibleItem)
            Box(
                modifier = Modifier
                    .align(Alignment.Center)
                    .background(
                        color = MaterialTheme.colorScheme.primary,
                        shape = CircleShape
                    )
                    .size(80.dp),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    text = indicatorChar,
                    color = MaterialTheme.colorScheme.onPrimary,
                    style = MaterialTheme.typography.headlineLarge
                )
            }
        }
    }
}
