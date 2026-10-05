package com.yourmateapps.pdfhelper

import android.Manifest
import android.content.ContentValues
import android.content.Context
import android.content.ContentUris
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.File
import java.io.IOException

/** Writes durable user documents, never app-specific external storage. */
internal class PublicPdfExporter(private val context: Context) {
    /** Mutate our MediaStore row even when broad storage access is disabled. */
    fun delete(uriString: String?, publicPath: String): Boolean {
        val uri = resolveOwnedUri(uriString, publicPath)
        if (uri != null) {
            val deleted = context.contentResolver.delete(uri, null, null)
            // A stable row URI that has already gone is safe to retry. Never
            // fall back to its old path, which another document may now use.
            if (deleted !in 0..1) {
                throw IOException("The public PDF could not be deleted")
            }
            return true
        }
        val file = File(publicPath)
        requireFilesystemAccess()
        if (file.exists() && !file.delete()) throw IOException("The public PDF could not be deleted")
        MediaScannerConnection.scanFile(context, arrayOf(publicPath), null, null)
        return true
    }

    fun rename(uriString: String?, publicPath: String, displayName: String): Map<String, String> {
        require(displayName.isNotBlank() && displayName != "." && displayName != ".." &&
            !displayName.contains('/') && !displayName.contains('\\')) { "Invalid file name" }
        val uri = resolveOwnedUri(uriString, publicPath)
        if (uri != null) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            }
            if (context.contentResolver.update(uri, values, null, null) != 1) {
                throw IOException("The public PDF could not be renamed")
            }
            return metadata(uri)
        }
        requireFilesystemAccess()
        val file = File(publicPath)
        require(file.isFile) { "The public PDF is missing" }
        val target = File(file.parentFile, displayName)
        if (target != file) {
            require(!target.exists()) { "A file with that name already exists" }
            if (!file.renameTo(target)) throw IOException("The public PDF could not be renamed")
            MediaScannerConnection.scanFile(context, arrayOf(file.path, target.path), null, null)
        }
        return mapOf("uri" to target.toURI().toString(), "name" to target.name, "publicPath" to target.path)
    }

    @Suppress("DEPRECATION")
    private fun requireFilesystemAccess() {
        val allowed = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || Environment.isExternalStorageLegacy()) &&
                context.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
        }
        if (!allowed) throw SecurityException(
            "The public copy is unavailable. Allow storage access or restore it to its original folder"
        )
    }

    /** Legacy records only stored paths. Recover their app-owned row first.
     * An empty scoped query is not proof of deletion: the row may be hidden. */
    @Suppress("DEPRECATION")
    private fun resolveOwnedUri(uriString: String?, publicPath: String): Uri? {
        val supplied = uriString?.let(Uri::parse)
        if (supplied?.scheme == "content") {
            require(supplied.authority == MediaStore.AUTHORITY) { "Unknown PDF storage provider" }
            require(supplied.lastPathSegment?.toLongOrNull() != null) { "Invalid PDF storage URI" }
            return supplied
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val collection = MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            context.contentResolver.query(collection, arrayOf(MediaStore.MediaColumns._ID),
                "${MediaStore.MediaColumns.DATA} = ?", arrayOf(publicPath), null)?.use {
                if (it.moveToFirst()) return ContentUris.withAppendedId(collection, it.getLong(0))
            }
        }
        return null
    }

    @Suppress("DEPRECATION")
    private fun metadata(uri: Uri): Map<String, String> {
        return context.contentResolver.query(uri, arrayOf(
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.RELATIVE_PATH,
        ), null, null, null)?.use { row ->
            if (!row.moveToFirst()) throw IOException("Could not find the public PDF after renaming")
            val name = row.getString(0)
            val relative = row.getString(1)
            if (name.isNullOrBlank() || relative.isNullOrBlank()) throw IOException("Could not read the public PDF location")
            mapOf("uri" to uri.toString(), "name" to name,
                "publicPath" to File(Environment.getExternalStorageDirectory(), File(relative, name).path).absolutePath)
        } ?: throw IOException("Could not read the public PDF location")
    }

    @Suppress("DEPRECATION")
    fun save(sourcePath: String, displayName: String, location: String): Map<String, String> {
        require(location == "Downloads" || location == "Documents") { "Unknown save location" }
        require(displayName.isNotBlank() && displayName != "." && displayName != ".." &&
            !displayName.contains('/') && !displayName.contains('\\')) { "Invalid file name" }
        val source = File(sourcePath)
        require(source.isFile && source.length() > 0) { "The PDF to save is missing or empty" }
        val directory = if (location == "Documents") Environment.DIRECTORY_DOCUMENTS
            else Environment.DIRECTORY_DOWNLOADS
        val relativePath = "$directory/PDFHelper/"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = context.contentResolver
            // Downloads only accepts Download/. Generic Files also accepts Documents/.
            val collection = if (location == "Documents")
                MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            else MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
                put(MediaStore.MediaColumns.MIME_TYPE, "application/pdf")
                put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            // The provider creates a unique name if a document already exists.
            val uri = resolver.insert(collection, values)
                ?: throw IOException("Could not create the PDF in $location")
            try {
                val output = resolver.openOutputStream(uri, "w")
                    ?: throw IOException("Could not write the PDF in $location")
                output.use { target -> source.inputStream().use { it.copyTo(target) } }
                val published = resolver.update(uri, ContentValues().apply {
                    put(MediaStore.MediaColumns.IS_PENDING, 0)
                }, null, null)
                if (published != 1) throw IOException("Could not publish the saved PDF")
                // Publishing may resolve a filename collision. Pending metadata
                // can still contain the requested name, so read the final row.
                val savedLocation = resolver.query(uri, arrayOf(
                    MediaStore.MediaColumns.DISPLAY_NAME,
                    MediaStore.MediaColumns.RELATIVE_PATH,
                ), null, null, null)?.use { row ->
                    if (!row.moveToFirst()) throw IOException("Could not find the saved PDF")
                    val name = row.getString(0)
                    val path = row.getString(1)
                    if (name.isNullOrBlank() || path.isNullOrBlank()) {
                        throw IOException("Could not read the saved PDF location")
                    }
                    name to path
                } ?: throw IOException("Could not read the saved PDF location")
                val (actualName, actualRelativePath) = savedLocation
                return mapOf(
                    "uri" to uri.toString(),
                    "name" to actualName,
                    "publicPath" to File(Environment.getExternalStorageDirectory(),
                        File(actualRelativePath, actualName).path).absolutePath,
                )
            } catch (error: Exception) {
                try { resolver.delete(uri, null, null) } catch (_: Exception) { }
                throw error
            }
        }

        // Android 9 and earlier require the legacy write grant; the Dart
        // caller requests it only on these OS versions.
        if (context.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
            PackageManager.PERMISSION_GRANTED) {
            throw SecurityException("Storage permission is needed to save to $location")
        }
        val folder = File(Environment.getExternalStoragePublicDirectory(directory), "PDFHelper")
        if (!folder.isDirectory && !folder.mkdirs()) throw IOException("Could not create $location/PDFHelper")
        val base = displayName.substringBeforeLast('.', displayName)
        val extension = displayName.substringAfterLast('.', "")
        var file = File(folder, displayName)
        var suffix = 2
        // Reserve the destination atomically so no existing document is replaced.
        while (!file.createNewFile()) {
            file = File(folder, "$base (${suffix++})" + if (extension.isEmpty()) "" else ".$extension")
        }
        try {
            file.outputStream().use { target -> source.inputStream().use { it.copyTo(target) } }
            MediaScannerConnection.scanFile(context, arrayOf(file.absolutePath), arrayOf("application/pdf"), null)
            return mapOf("uri" to file.toURI().toString(), "name" to file.name, "publicPath" to file.absolutePath)
        } catch (error: Exception) {
            file.delete()
            throw error
        }
    }
}
