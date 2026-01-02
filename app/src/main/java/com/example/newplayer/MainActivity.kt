package com.example.newplayer

import android.content.ComponentName
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
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
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Album
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
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
import com.example.newplayer.data.Album
import com.example.newplayer.data.AppDatabase
import com.example.newplayer.data.Artist
import com.example.newplayer.data.LocalSongRepository
import com.example.newplayer.data.Song
import com.example.newplayer.ui.theme.NewPlayerTheme
import com.google.common.util.concurrent.MoreExecutors
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch


sealed class Screen(val route: String, val title: String, val icon: ImageVector) {
    data object Songs : Screen("songs", "Songs", Icons.Default.MusicNote)
    data object Artists : Screen("artists", "Artists", Icons.Default.Person)
    data object Albums : Screen("albums", "Albums", Icons.Default.Album)
}

val navigationItems = listOf(
    Screen.Songs,
    Screen.Artists,
    Screen.Albums,
)

class MainActivity : ComponentActivity() {

    private lateinit var database: AppDatabase
    private lateinit var repository: LocalSongRepository
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        database = AppDatabase.getDatabase(applicationContext)
        repository = LocalSongRepository(this,
            database.songDao(), database.artistDao(), database.albumDao())
        setContent {
            NewPlayerTheme {
                var isScanning by remember { mutableStateOf(false) }
                val scope = rememberCoroutineScope()
                val context = LocalContext.current
                var mediaController by remember { mutableStateOf<MediaController?>(null) }

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
                            isScanning = true
                            repository.scanForSongs()
                            isScanning = false
                        }
                    }
                }

                AppRoot(
                    repository = repository,
                    isScanning = isScanning,
                    onScanSongs = {
                        scope.launch {
                            isScanning = true
                            repository.scanForSongs()
                            isScanning = false
                        }
                    },
                    mediaController = mediaController
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
    mediaController: MediaController?
) {
    val navController = rememberNavController()
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("New Player") },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.primaryContainer,
                    titleContentColor = MaterialTheme.colorScheme.primary,
                )
            )
        },
        bottomBar = {
            Column {
                mediaController?.let { MiniPlayer(it) }
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
                ArtistListScreen(repository, navController)
            }
            composable(Screen.Albums.route) {
                AlbumListScreen(repository, navController)
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
                    AlbumSongListScreen(repository, albumId, onBack = { navController.popBackStack() }, mediaController)
                }
            }
        }
    }
}

@Composable
fun MiniPlayer(mediaController: MediaController) {
    var currentMediaItem by remember { mutableStateOf(mediaController.currentMediaItem) }
    var isPlaying by remember { mutableStateOf(mediaController.isPlaying) }

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
            .padding(8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
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
fun SongListScreen(
    repository: LocalSongRepository,
    isScanning: Boolean,
    modifier: Modifier = Modifier
) {
    val songs by repository.allSongs.collectAsState(initial = emptyList())
    val sortedSongs = songs.sortedBy { it.title }

    Box(modifier = modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        if (isScanning) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                CircularProgressIndicator()
                Spacer(modifier = Modifier.height(8.dp))
                Text("Scanning for music...")
            }
        } else {
            FastScrollLazyColumn(
                modifier = Modifier.fillMaxSize(),
                items = sortedSongs,
                itemContent = { song -> SongListItem(song) },
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
    val artists by repository.allArtists.collectAsState(initial = emptyList())
    val sortedArtists = artists.sortedBy { it.name }

    FastScrollLazyColumn(
        modifier = modifier.fillMaxSize(),
        items = sortedArtists,
        itemContent = { artist ->
            ListItem(
                headlineContent = { Text(artist.name) },
                modifier = Modifier.clickable { navController.navigate("artist_albums/${artist.id}") }
            )
        },
        indicatorContent = { artist -> artist.name.firstOrNull()?.uppercase() ?: "#" },
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
    val sortedAlbums = albums.sortedBy { it.name }

    Scaffold(
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
            modifier = Modifier.fillMaxSize().padding(innerPadding),
            items = sortedAlbums,
            itemContent = { album ->
                ListItem(
                    headlineContent = { Text(album.name) },
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
fun AlbumSongListScreen(repository: LocalSongRepository, albumId: Long, onBack: () -> Unit, mediaController: MediaController?) {
    val album by repository.getAlbumById(albumId).collectAsState(initial = null)
    val songs by repository.getSongsByAlbumId(albumId).collectAsState(initial = emptyList())

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(album?.name ?: "Songs") },
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
        },
        floatingActionButton = {
            if (songs.isNotEmpty()) {
                FloatingActionButton(onClick = {
                    mediaController?.let {
                        val mediaItems = songs.map { song ->
                            MediaItem.Builder()
                                .setUri(song.path)
                                .setMediaId(song.id.toString())
                                .setMediaMetadata(
                                    androidx.media3.common.MediaMetadata.Builder()
                                        .setTitle(song.title)
                                        .setArtist(song.artist)
                                        .setAlbumTitle(song.album)
                                        .build()
                                )
                                .build()
                        }
                        it.setMediaItems(mediaItems)
                        it.prepare()
                        it.play()
                    }
                }) {
                    Icon(Icons.Default.PlayArrow, contentDescription = "Play album")
                }
            }
        }
    ) { innerPadding ->
        LazyColumn(modifier = Modifier.fillMaxSize().padding(innerPadding)) {
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
                        }
                    )
                }
            }
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
