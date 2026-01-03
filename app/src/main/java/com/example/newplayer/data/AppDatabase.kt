package com.example.newplayer.data

import android.content.Context
import androidx.room.AutoMigration
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import com.example.player.data.Profile
import com.example.player.data.ProfileDao

@Database(
    entities = [Profile::class, Song::class, Artist::class, Album::class],
    version = 9,
    exportSchema = true,
    autoMigrations = [
        AutoMigration(from = 8, to = 9)
    ]
)
abstract class AppDatabase : RoomDatabase() {
    abstract fun songDao(): SongDao
    abstract fun artistDao(): ArtistDao
    abstract fun albumDao(): AlbumDao
    abstract fun profileDao(): ProfileDao

    companion object {
        @Volatile
        private var INSTANCE: AppDatabase? = null

        fun getDatabase(context: Context): AppDatabase {
            return INSTANCE ?: synchronized(this) {
                val instance = Room.databaseBuilder(
                    context.applicationContext,
                    AppDatabase::class.java,
                    "song_database"
                )
                .build()
                INSTANCE = instance
                instance
            }
        }
    }
}
