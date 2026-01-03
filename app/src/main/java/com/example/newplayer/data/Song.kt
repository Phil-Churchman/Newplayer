package com.example.newplayer.data

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.PrimaryKey
import com.example.player.data.Profile

@Entity(tableName = "songs",
    foreignKeys = [ForeignKey(
        entity = Profile::class,
        parentColumns = ["id"],
        childColumns = ["profileId"],
        onDelete = ForeignKey.CASCADE
    )
    ])
data class Song(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val title: String,
    val artist: String,
    val album: String,
    val path: String,
    val duration: Long,
    val albumArtist: String,
    val albumId: Long,
    val track: Int,
    @ColumnInfo(defaultValue = "1")
    val profileId: Long = 1
)
