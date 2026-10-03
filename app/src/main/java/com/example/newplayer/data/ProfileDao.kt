package com.example.newplayer.data

import androidx.room.Dao
import androidx.room.Delete
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Transaction
import androidx.room.Update
import kotlinx.coroutines.flow.Flow

@Dao
interface ProfileDao {

    @Insert
    suspend fun insert(profile: Profile)

    @Update
    suspend fun update(profile: Profile)

    @Delete
    suspend fun delete(profile: Profile)

    @Query("SELECT * FROM profiles ORDER BY name ASC")
    fun getAllProfiles(): Flow<List<Profile>>

    @Query("UPDATE profiles SET isActive = 0")
    suspend fun resetActiveProfiles()

    @Transaction
    suspend fun setActiveProfile(profile: Profile) {
        resetActiveProfiles()
        update(profile.copy(isActive = true))
    }
    @Query("SELECT * FROM profiles WHERE isActive = 1 LIMIT 1")
    fun getActiveProfileBlocking(): Profile?
    @Query("SELECT * FROM profiles WHERE isActive = 1 LIMIT 1")
    fun getActiveProfile(): Flow<Profile?>

    @Query("UPDATE profiles SET isActive = CASE WHEN id = :profileId THEN 1 ELSE 0 END")
    suspend fun setActiveProfileById(profileId: Long)

    @Query("SELECT * FROM profiles WHERE isActive = 1 LIMIT 1")
    fun getActiveProfileFlow(): Flow<Profile?>
    @Query("SELECT * FROM profiles WHERE name = :name LIMIT 1")
    fun getProfileByName(name: String): Profile?

    @Query("SELECT EXISTS(SELECT 1 FROM profiles WHERE name = 'Local' AND isActive = 1)")
    fun isLocalProfileActive(): Boolean

    @Query("SELECT EXISTS(SELECT 1 FROM profiles WHERE name = 'Local' AND isActive = 1)")
    fun isLocalProfileActiveFlow(): Flow<Boolean>

    @Query("SELECT id FROM profiles WHERE name = 'Local' LIMIT 1")
    suspend fun getLocalProfileId(): Long?
}