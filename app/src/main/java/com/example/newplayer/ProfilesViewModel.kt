package com.example.newplayer

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.example.player.data.Profile
import com.example.player.data.ProfileDao
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import com.example.newplayer.data.LocalSongRepository



data class ProfilesScreenUiState(
    val profiles: List<Profile> = emptyList(),
    val activeProfile: Profile? = null,
    val connectionErrorProfileId: Long? = null,
    val syncingProfileId: Long? = null,
    val lastSyncStatus: SyncStatus = SyncStatus.IDLE,
    val lastSyncProfileId: Long? = null
)

class ProfilesViewModel(
    private val profileDao: ProfileDao,
    private val mpdClient: MpdClient,
    private val localSongRepository: LocalSongRepository
) : ViewModel() {

    private val _uiState = MutableStateFlow(ProfilesScreenUiState())
    val uiState: StateFlow<ProfilesScreenUiState> = _uiState.asStateFlow()

    private val _profileChangedFlow = MutableSharedFlow<Unit>()
    val profileChangedFlow = _profileChangedFlow.asSharedFlow()

    init {
        viewModelScope.launch(Dispatchers.IO) {
            launch {
                profileDao.getAllProfiles()
                    .collect { profiles ->
                        _uiState.update { it.copy(profiles = profiles) }
                    }
            }
            launch {
                profileDao.getActiveProfileFlow()
                    .collect { activeProfile ->
                        _uiState.update { it.copy(activeProfile = activeProfile) }
                    }
            }
        }
    }

    fun addProfile(name: String, host: String, port: Int) {
        viewModelScope.launch {
            profileDao.insert(Profile(name = name, host = host, port = port))
        }
    }

    fun createLocalProfile() {
        viewModelScope.launch {
            profileDao.insert(Profile(name = "Local", host = "", port = 0))
        }
    }

    fun updateProfile(profile: Profile) {
        viewModelScope.launch {
            profileDao.update(profile)
        }
    }

    fun deleteProfile(profile: Profile) {
        viewModelScope.launch {
            profileDao.delete(profile)
        }
    }

    fun setActiveProfile(profile: Profile) {
        viewModelScope.launch {
            if (profile.name == "Local") {
                profileDao.setActiveProfileById(profile.id)
                _uiState.update { it.copy(connectionErrorProfileId = null) }
                _profileChangedFlow.emit(Unit)
            } else {
                try {
                    // First, reconnect the client. This will throw an exception on failure.
                    mpdClient.reconnect(profile)

                    // If reconnection is successful, then update the active profile in the database.
                    profileDao.setActiveProfileById(profile.id)

                    // Clear any previous connection error for this profile.
                    _uiState.update { it.copy(connectionErrorProfileId = null) }
                    _profileChangedFlow.emit(Unit)

                } catch (e: Exception) {
                    // If reconnect fails, show an error and do not change the active profile.
                    _uiState.update { it.copy(connectionErrorProfileId = profile.id) }
                }
            }
        }
    }

    fun syncLibrary(profile: Profile) {
//        if (_uiState.value.syncingProfileId != null) return
//
//        viewModelScope.launch {
//            _uiState.update {
//                it.copy(
//                    syncingProfileId = profile.id,
//                    lastSyncStatus = SyncStatus.SYNCING,
//                    lastSyncProfileId = profile.id
//                )
//            }
//            try {
//                if (profile.name == "Local") {
//                    localSongRepository.sync(profile.id)
//                    _uiState.update { it.copy(lastSyncStatus = SyncStatus.SUCCESS) }
//                } else {
//                    if (mpdClient.ping(profile.host, profile.port)) {
//                        _uiState.update { it.copy(connectionErrorProfileId = null) }
//                        songRepository.syncLibrary(profile.id)
//                        _uiState.update { it.copy(lastSyncStatus = SyncStatus.SUCCESS) }
//                    } else {
//                        _uiState.update {
//                            it.copy(
//                                connectionErrorProfileId = profile.id,
//                                lastSyncStatus = SyncStatus.FAILED
//                            )
//                        }
//                    }
//                }
//            } catch (e: Exception) {
//                _uiState.update {
//                    it.copy(
//                        connectionErrorProfileId = if (profile.name == "Local") null else profile.id,
//                        lastSyncStatus = SyncStatus.FAILED
//                    )
//                }
//            } finally {
//                delay(3000)
//                _uiState.update {
//                    it.copy(
//                        syncingProfileId = null,
//                        lastSyncStatus = SyncStatus.IDLE,
//                        lastSyncProfileId = null
//                    )
//                }
//            }
//        }
    }
}