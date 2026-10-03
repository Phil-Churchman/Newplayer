package com.example.newplayer

import com.example.newplayer.data.Profile
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.PrintWriter
import java.net.Socket

class MpdClient {

    private var socket: Socket? = null
    private var writer: PrintWriter? = null
    private var reader: BufferedReader? = null

    suspend fun reconnect(profile: Profile) {
        withContext(Dispatchers.IO) {
            disconnect()
            socket = Socket(profile.host, profile.port)
            writer = PrintWriter(socket!!.getOutputStream(), true)
            reader = BufferedReader(InputStreamReader(socket!!.getInputStream()))
            // Read the initial "OK MPD" line
            reader!!.readLine()
        }
    }

    suspend fun ping(host: String, port: Int): Boolean {
        return withContext(Dispatchers.IO) {
            try {
                Socket(host, port).use {
                    // Check if it's actually an MPD server
                    val reader = BufferedReader(InputStreamReader(it.getInputStream()))
                    val response = reader.readLine()
                    response?.startsWith("OK MPD") == true
                }
            } catch (e: Exception) {
                false
            }
        }
    }


    private fun disconnect() {
        writer?.close()
        reader?.close()
        socket?.close()
    }
}