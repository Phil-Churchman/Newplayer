import android.graphics.Bitmap
import android.graphics.BitmapFactory
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStreamWriter
import java.net.Socket
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlin.apply
import kotlin.io.buffered
import kotlin.io.use
import kotlin.let
import kotlin.text.isNotEmpty
import kotlin.text.startsWith
import kotlin.text.substringAfter
import kotlin.text.toIntOrNull
import kotlin.text.trim
import kotlin.to

object MPDAlbumArtDownloader {

    private const val MAX_BLOB_SIZE = 40_000_000 // limit for download
    private const val MAX_IMAGE_DIMENSION = 512 // The longest dimension will be scaled to this size

    suspend fun downloadAlbumArt(host: String, port: Int, songPath: String): ByteArray? {
        return withContext(Dispatchers.IO) {
            val rawImageData = try {
                tryWithReadPicture(host, port, songPath)
            } catch (e: Exception) {
                e.printStackTrace()
                null
            } ?: try {
                tryWithAlbumArt(host, port, songPath)
            } catch (e: Exception) {
                e.printStackTrace()
                null
            }
//            val rawImageData = try {
//                tryWithAlbumArt(host, port, songPath)
//            } catch (e: Exception) {
//                e.printStackTrace()
//                null
//            } ?: try {
//                tryWithReadPicture(host, port, songPath)
//            } catch (e: Exception) {
//                e.printStackTrace()
//                null
//            }
            // If we have data, scale it if necessary. Otherwise return null.
            rawImageData?.let { scaleImageIfNecessary(it, MAX_IMAGE_DIMENSION) }
        }
    }

    private fun tryWithReadPicture(host: String, port: Int, songPath: String): ByteArray? {
        Socket(host, port).use { socket ->
            val input = socket.getInputStream().buffered()
            val writer = OutputStreamWriter(socket.getOutputStream())
            readLine(input) // Consume the MPD server greeting
            return fetchWithReadPicture(input, writer, songPath)
        }
    }

    private fun tryWithAlbumArt(host: String, port: Int, songPath: String): ByteArray? {
        Socket(host, port).use { socket ->
            val input = socket.getInputStream().buffered()
            val writer = OutputStreamWriter(socket.getOutputStream())
            readLine(input) // Consume the MPD server greeting
            return fetchWithAlbumArt(input, writer, songPath)
        }
    }

    private fun fetchWithReadPicture(input: InputStream, writer: OutputStreamWriter, songPath: String): ByteArray? {
        var offset = 0
        ByteArrayOutputStream().use { output ->
            while (true) {
                writer.write("readpicture \"$songPath\" $offset\n")
                writer.flush()

                val (binarySize, error) = readHeaders(input)
                if (error != null) return null // Command failed or connection error
                if (binarySize == null || binarySize == 0) break // No more data

                if (output.size() + binarySize > MAX_BLOB_SIZE) {
                    readChunk(input, binarySize) // Read and discard the oversized chunk
                    readLine(input) // Consume the trailing "OK"
                    return null // Image too large
                }

                val chunk = readChunk(input, binarySize) ?: return null
                output.write(chunk)
                offset += binarySize

                readLine(input) // Read trailing "OK" for the chunk
            }
            if (output.size() > 0) {
                return output.toByteArray()
            }
        }
        return null
    }
    private fun fetchWithAlbumArt(input: InputStream, writer: OutputStreamWriter, songPath: String): ByteArray? {
        var offset = 0
        ByteArrayOutputStream().use { output ->
            while (true) {
                writer.write("albumart \"$songPath\" $offset\n")
                writer.flush()

                val (binarySize, error) = readHeaders(input)
                if (error != null) return null // Command failed or connection error
                if (binarySize == null || binarySize == 0) break // No more data

                if (output.size() + binarySize > MAX_BLOB_SIZE) {
                    readChunk(input, binarySize) // Read and discard the oversized chunk
                    readLine(input) // Consume the trailing "OK"
                    return null // Image too large
                }

                val chunk = readChunk(input, binarySize) ?: return null
                output.write(chunk)
                offset += binarySize

                readLine(input) // Read trailing "OK" for the chunk
            }
            if (output.size() > 0) {
                return output.toByteArray()
            }
        }
        return null
    }
//    private fun fetchWithAlbumArt(input: InputStream, writer: OutputStreamWriter, songPath: String): ByteArray? {
//        writer.write("albumart \"$songPath\"\n")
//        writer.flush()
//
//        val (binarySize, error) = readHeaders(input)
//        if (error != null || binarySize == null || binarySize == 0) {
//            return null
//        }
//
//        if (binarySize > MAX_BLOB_SIZE) {
//            readChunk(input, binarySize) // Read and discard oversized image data
//            readLine(input) // Consume the trailing "OK"
//            return null // Image is too large for the database
//        }
//
//        val imageBytes = readChunk(input, binarySize) ?: return null
//        readLine(input) // Read trailing "OK"
//        return imageBytes
//    }

    private fun scaleImageIfNecessary(imageData: ByteArray, maxDimension: Int): ByteArray {
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(imageData, 0, imageData.size, options)

        val width = options.outWidth
        val height = options.outHeight

        // If the image is already within bounds, return the original data.
        if (width <= maxDimension && height <= maxDimension) {
            return imageData
        }

        // Calculate the new dimensions while maintaining the aspect ratio.
        val (newWidth, newHeight) = if (width > height) {
            val ratio = width.toFloat() / height.toFloat()
            maxDimension to (maxDimension / ratio).toInt()
        } else {
            val ratio = height.toFloat() / width.toFloat()
            (maxDimension / ratio).toInt() to maxDimension
        }

        // Decode the full bitmap, scale it, and compress it back to a ByteArray.
        val originalBitmap = BitmapFactory.decodeByteArray(imageData, 0, imageData.size) ?: return imageData
        val scaledBitmap = Bitmap.createScaledBitmap(originalBitmap, newWidth, newHeight, true)

        if (originalBitmap != scaledBitmap) {
            originalBitmap.recycle()
        }

        ByteArrayOutputStream().use { stream ->
            // Use JPEG format for compression. 85 is a good quality/size trade-off.
            scaledBitmap.compress(Bitmap.CompressFormat.JPEG, 85, stream)
            scaledBitmap.recycle()
            return stream.toByteArray()
        }
    }

    private fun readHeaders(input: InputStream): Pair<Int?, String?> {
        while (true) {
            val line = readLine(input) ?: return Pair(null, "Connection closed")
            when {
                line.startsWith("ACK") -> return Pair(null, line) // Error from MPD
                line.startsWith("binary:") -> {
                    val binarySize = line.substringAfter("binary:").trim().toIntOrNull()
                    return Pair(binarySize, null) // Found size, return immediately.
                }
//                line.startsWith("OK") -> return Pair(null, null) // Command successful, but no binary data.
            }
        }
    }

    private fun readChunk(input: InputStream, size: Int): ByteArray? {
        val chunk = ByteArray(size)
        var read = 0
        while (read < size) {
            val n = input.read(chunk, read, size - read)
            if (n <= 0) return null // Connection closed unexpectedly
            read += n
        }
        return chunk
    }

    private fun readLine(input: InputStream): String? {
        val sb = kotlin.text.StringBuilder()
        while (true) {
            val b = input.read()
            if (b == -1) return if (sb.isNotEmpty()) sb.toString() else null
            if (b.toChar() == '\n') break
            if (b.toChar() != '\r') sb.append(b.toChar())
        }
        return sb.toString()
    }
}

// The main function is updated to test the new suspend function
fun main() = runBlocking {
    val host = "192.168.68.154"
    val port = 6600
    val songPath = "path/to/your/song.flac" // CHANGE THIS to a valid song path on your MPD server

    val imageData = MPDAlbumArtDownloader.downloadAlbumArt(host, port, songPath)
    if (imageData != null) {
        println("Successfully downloaded album art, size: ${imageData.size} bytes.")
        // In your Android app, you would now convert this to a Bitmap.
    } else {
        println("Failed to download album art.")
    }
}
