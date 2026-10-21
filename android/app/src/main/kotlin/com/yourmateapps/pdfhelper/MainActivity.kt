package com.yourmateapps.pdfhelper

import android.content.Intent
import android.Manifest
import android.annotation.TargetApi
import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.storage.StorageManager
import android.provider.Settings
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {

    private val pdfIo = Executors.newSingleThreadExecutor()

    private val CHANNEL = "com.yourmateapps.pdfhelper/pdf"

    override fun onNewIntent(intent: Intent) {
        // Plugins can notify Dart synchronously from super.onNewIntent.
        setIntent(intent)
        super.onNewIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.yourmateapps.pdfhelper/diagnostics")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "recentExits" -> result.success(
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) recentMemoryExits() else emptyList()
                    )
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.yourmateapps.pdfhelper/storage")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "getStorageInfo" -> result.success(storageInfo())
                        "openStorageSettings" -> {
                            openStorageSettings()
                            result.success(null)
                        }
                        "savePublicPdf" -> {
                            val source = call.argument<String>("sourcePath")
                            val name = call.argument<String>("displayName")
                            val location = call.argument<String>("location")
                            // Any kind of document; PDF unless the caller says otherwise.
                            val mimeType = call.argument<String>("mimeType") ?: "application/pdf"
                            // A folder below DocHelper, such as an extracted archive's.
                            val subfolder = call.argument<String>("subfolder")
                            require(source != null && name != null && location != null) { "Missing save details" }
                            pdfIo.execute {
                                try {
                                    val saved = PublicPdfExporter(applicationContext)
                                        .save(source, name, location, mimeType, subfolder)
                                    runOnUiThread { result.success(saved) }
                                } catch (e: Exception) {
                                    runOnUiThread { result.error("PUBLIC_SAVE_FAILED", e.message, null) }
                                }
                            }
                        }
                        "updatePublicFile" -> {
                            val source = call.argument<String>("sourcePath")
                            val path = call.argument<String>("publicPath")
                            val uri = call.argument<String>("uri")
                            require(source != null && !path.isNullOrBlank()) { "Missing save details" }
                            pdfIo.execute {
                                try {
                                    val saved = PublicPdfExporter(applicationContext).update(uri, path, source)
                                    runOnUiThread { result.success(saved) }
                                } catch (e: Exception) {
                                    runOnUiThread { result.error("PUBLIC_SAVE_FAILED", e.message, null) }
                                }
                            }
                        }
                        "deletePublicPdf", "renamePublicPdf" -> {
                            val path = call.argument<String>("publicPath")
                            val uri = call.argument<String>("uri")
                            val name = call.argument<String>("displayName")
                            require(!path.isNullOrBlank()) { "Missing public PDF location" }
                            if (call.method == "renamePublicPdf") require(!name.isNullOrBlank()) { "Missing PDF name" }
                            pdfIo.execute {
                                try {
                                    val exporter = PublicPdfExporter(applicationContext)
                                    val changed: Any = if (call.method == "deletePublicPdf")
                                        exporter.delete(uri, path) else exporter.rename(uri, path, name!!)
                                    runOnUiThread { result.success(changed) }
                                } catch (e: Exception) {
                                    runOnUiThread { result.error("PUBLIC_MUTATION_FAILED", e.message, null) }
                                }
                            }
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("STORAGE_ERROR", e.message, null)
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "resolvePdfUri" -> {
                    val uriString = call.argument<String>("uri")
                    if (uriString.isNullOrEmpty()) {
                        result.error("INVALID", "URI is null or empty", null)
                        return@setMethodCallHandler
                    }
                    resolvePdfAsync(uriString, result, false)
                }
                "getPdfIntentData" -> {
                    val pending = PendingPdfIntent.take()
                    val incoming = intent
                    val uriString = pending?.first ?: incoming?.takeIf {
                        it.action == Intent.ACTION_VIEW ||
                            it.hasExtra(PdfIntentTrampolineActivity.EXTRA_PDF_ACTION)
                    }?.data?.toString()
                    // Consume this delivery before starting I/O: startup and the
                    // resumed-intent listener may both ask for it.
                    incoming?.data = null
                    incoming?.removeExtra(PdfIntentTrampolineActivity.EXTRA_PDF_ACTION)
                    if (uriString == null) result.success(null)
                    else resolvePdfAsync(uriString, result, true)
                }
                "getPdfIntentAction" -> {
                    val fromExtra = intent?.getStringExtra(PdfIntentTrampolineActivity.EXTRA_PDF_ACTION)
                    if (fromExtra != null) {
                        result.success(fromExtra)
                        return@setMethodCallHandler
                    }
                    result.success("view")
                }
                else -> result.notImplemented()
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun storageInfo(): Map<String, Any> {
        val hasFullAccess = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            val legacy = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
                Environment.isExternalStorageLegacy()
            legacy && checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
        }
        val roots = linkedSetOf<String>()
        fun addRoot(directory: File?) {
            if (directory == null) return
            roots.add(try { directory.canonicalPath } catch (_: Exception) { directory.absolutePath })
        }
        // The OS supplies the current user's primary storage path. Hardcoding
        // /storage/emulated/0 misses secondary users and work profiles.
        addRoot(Environment.getExternalStorageDirectory())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val manager = getSystemService(StorageManager::class.java)
            for (volume in manager?.storageVolumes.orEmpty()) addRoot(volume.directory)
        }
        // Also discovers removable volumes on Android 10 and earlier.
        for (directory in getExternalFilesDirs(null)) {
            val path = directory?.absolutePath ?: continue
            val marker = path.indexOf("/Android/data/")
            if (marker > 0) addRoot(File(path.substring(0, marker)))
        }
        return mapOf(
            "sdkInt" to Build.VERSION.SDK_INT,
            "hasFullAccess" to hasFullAccess,
            "roots" to roots.toList(),
        )
    }

    private fun openStorageSettings() {
        val appUri = Uri.parse("package:$packageName")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                startActivity(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, appUri))
            } catch (_: android.content.ActivityNotFoundException) {
                startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
            }
        } else {
            startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, appUri))
        }
    }

    private fun resolvePdfAsync(uriString: String, result: MethodChannel.Result, asIntent: Boolean) {
        pdfIo.execute {
            try {
                val path = resolveUriToPath(uriString)
                    ?: throw IllegalArgumentException("Only local documents can be opened")
                runOnUiThread {
                    result.success(if (asIntent) mapOf("path" to path, "action" to "view") else path)
                }
            } catch (e: Exception) {
                runOnUiThread {
                    result.error("RESOLVE_ERROR", "This document could not be opened. Choose the file again from its source app.", null)
                }
            }
        }
    }

    /** The extension DocHelper opens a document as, from its name or, when
     * the name has none it knows, its MIME type. Null for kinds it does not
     * open (yet). Keep in step with the intent filters in the manifest. */
    private fun documentExtension(name: String?, mimeType: String?): String? {
        val fromName = name?.substringAfterLast('.', "")?.lowercase()
        if (fromName != null && fromName in OPENABLE_EXTENSIONS) return fromName
        val type = mimeType?.lowercase()?.substringBefore(';')?.trim() ?: return null
        return MIME_EXTENSIONS[type] ?: if (type.startsWith("text/")) "txt" else null
    }

    /** PDFs must look like PDFs, Office packages and archives like ZIP,
     * gzip or TAR files, and flat OpenDocument files like their XML. Text
     * and CSV have no signature; their engines read any bytes. */
    private fun requireDocumentContent(extension: String, header: ByteArray) {
        if (extension == "pdf") requirePdfHeader(header)
        if (extension in ZIP_EXTENSIONS) {
            require(header.size >= 4 && header[0] == 'P'.code.toByte() && header[1] == 'K'.code.toByte()) {
                "The selected document is not an Office document"
            }
        }
        when (extension) {
            "zip" -> require(isZip(header)) { "The selected file is not a ZIP archive" }
            "gz", "tgz" -> require(isGzip(header)) { "The selected file is not a gzip archive" }
            "tar" -> require(isTar(header)) { "The selected file is not a TAR archive" }
        }
        FLAT_ODF_TYPES[extension]?.let { type ->
            require(isFlatOpenDocument(header, type)) { "The selected document is not an OpenDocument file" }
        }
    }

    /** The extension of the archive [header] begins, for a document whose
     * name and type say nothing DocHelper opens: a ZIP without an Office
     * extension opens as a .zip. Null when it is no archive. */
    private fun sniffArchive(header: ByteArray): String? = when {
        isZip(header) -> "zip"
        isGzip(header) -> "gz"
        isTar(header) -> "tar"
        else -> null
    }

    /** A local file header ("PK\3\4"), or the end record of an empty ZIP. */
    private fun isZip(header: ByteArray): Boolean =
        header.size >= 4 && header[0] == 'P'.code.toByte() && header[1] == 'K'.code.toByte() &&
            ((header[2] == 3.toByte() && header[3] == 4.toByte()) ||
                (header[2] == 5.toByte() && header[3] == 6.toByte()))

    private fun isGzip(header: ByteArray): Boolean =
        header.size >= 2 && header[0] == 0x1F.toByte() && header[1] == 0x8B.toByte()

    /** POSIX and GNU TAR headers say "ustar" at offset 257. */
    private fun isTar(header: ByteArray): Boolean =
        header.size >= 262 && String(header, 257, 5, Charsets.ISO_8859_1) == "ustar"

    /** A flat OpenDocument file is one XML document: its root element is
     * office:document, whose office:mimetype names the kind (or its
     * template). [kind] is "text", "spreadsheet" or "presentation". */
    private fun isFlatOpenDocument(header: ByteArray, kind: String): Boolean {
        val text = String(header, Charsets.ISO_8859_1)
        if (!Regex("<office:document[\\s>]").containsMatchIn(text)) return false
        val declared = Regex("office:mimetype\\s*=\\s*[\"']application/vnd\\.oasis\\.opendocument\\.([a-z-]+)[\"']")
            .find(text)?.groupValues?.get(1)
        return declared == kind || declared == "$kind-template"
    }

    private fun resolveUriToPath(uriString: String): String? {
        val uri = Uri.parse(uriString)
        return when (uri.scheme) {
            "file" -> {
                val file = File(uri.path ?: return null).canonicalFile
                // An exported intent must never grant access to private app data.
                val privateRoot = File(applicationInfo.dataDir).canonicalPath
                require(!file.path.startsWith("$privateRoot/"))
                require(file.isFile && file.canRead())
                val extension = documentExtension(file.name, intent?.type)
                    ?: throw IllegalArgumentException("DocHelper cannot open this kind of file")
                require(file.extension.lowercase() == extension) { "The file name does not match its type" }
                file.inputStream().use { input -> requireDocumentContent(extension, readHeader(input)) }
                file.path
            }
            "content" -> copyContentToTemp(uri)
            else -> null
        }
    }

    /** The first [HEADER_BYTES] of a document: enough for a flat
     * OpenDocument file's root element and its many namespaces. */
    private fun readHeader(input: java.io.InputStream): ByteArray {
        val bytes = ByteArray(HEADER_BYTES)
        var count = 0
        while (count < bytes.size) {
            val read = input.read(bytes, count, bytes.size - count)
            if (read < 0) break
            count += read
        }
        return bytes.copyOf(count)
    }

    private fun requirePdfHeader(header: ByteArray) {
        // The header may follow up to 1 KB of junk, as viewers allow.
        require(String(header, 0, minOf(header.size, 1024), Charsets.ISO_8859_1).contains("%PDF-")) {
            "The selected document is not a PDF"
        }
    }

    private fun copyContentToTemp(uri: Uri): String {
        var fileName: String? = null
        try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (nameIndex >= 0) cursor.getString(nameIndex)?.let { fileName = it }
                }
            }
        } catch (_: Exception) {
            // Providers are allowed to omit display names.
        }
        val mimeType = try { contentResolver.getType(uri) } catch (_: Exception) { null }
        val declared = documentExtension(fileName, mimeType ?: intent?.type)
        val input = contentResolver.openInputStream(uri)
            ?: throw IllegalArgumentException("The document provider returned no data")
        return input.use {
            val header = readHeader(it)
            // Providers often send archives as application/octet-stream with
            // no usable name; their content still says what they are.
            val extension = declared ?: sniffArchive(header)
                ?: throw IllegalArgumentException("DocHelper cannot open this kind of file")
            requireDocumentContent(extension, header)
            // Display names are untrusted provider input, never path components.
            var safeName = (fileName ?: "opened.$extension")
                .replace(Regex("[\\\\/\\p{Cntrl}]"), "_").take(60)
            if (!safeName.endsWith(".$extension", ignoreCase = true)) safeName += ".$extension"
            val directory = File(cacheDir, "opened_documents").apply { mkdirs() }
            val tempFile = File.createTempFile("intent_", "_$safeName", directory)
            try {
                FileOutputStream(tempFile).use { output ->
                    output.write(header)
                    val buffer = ByteArray(64 * 1024)
                    var total = header.size.toLong()
                    while (true) {
                        val count = it.read(buffer)
                        if (count < 0) break
                        total += count
                        require(total <= 512L * 1024 * 1024) { "The document exceeds the 512 MB import limit" }
                        output.write(buffer, 0, count)
                    }
                }
                tempFile.absolutePath
            } catch (e: Exception) {
                tempFile.delete()
                throw e
            }
        }
    }

    companion object {
        /** How much of a document is read to check what it is. */
        private const val HEADER_BYTES = 16 * 1024

        /** Extensions DocHelper opens from other apps. */
        private val OPENABLE_EXTENSIONS = setOf(
            "pdf", "txt", "text", "log", "md", "markdown", "json", "html", "htm",
            "xlsx", "xlsm", "xltx", "xltm", "ods", "ots", "fods", "csv", "tsv",
            "xls", "xlt", "et", "ett",
            "docx", "docm", "dotx", "dotm", "odt", "ott", "fodt", "rtf",
            "doc", "dot", "wps", "wpt",
            "pptx", "pptm", "ppsx", "ppsm", "potx", "potm", "odp", "otp", "fodp",
            "ppt", "pps", "pot", "dps", "dpt",
            "zip", "tar", "gz", "tgz",
        )

        /** Flat OpenDocument extensions, and the kind their XML declares. */
        private val FLAT_ODF_TYPES = mapOf(
            "fodt" to "text",
            "fods" to "spreadsheet",
            "fodp" to "presentation",
        )

        /** Formats that are ZIP packages, which must start like one. */
        private val ZIP_EXTENSIONS = setOf(
            "xlsx", "xlsm", "xltx", "xltm", "ods", "ots",
            "docx", "docm", "dotx", "dotm", "odt", "ott",
            "pptx", "pptm", "ppsx", "ppsm", "potx", "potm", "odp", "otp",
        )

        private val MIME_EXTENSIONS = mapOf(
            "application/pdf" to "pdf",
            "text/plain" to "txt",
            "text/markdown" to "md",
            "text/x-markdown" to "md",
            "application/json" to "json",
            "text/html" to "html",
            "application/xhtml+xml" to "html",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" to "xlsx",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.template" to "xltx",
            "application/vnd.ms-excel.sheet.macroenabled.12" to "xlsm",
            "application/vnd.oasis.opendocument.spreadsheet" to "ods",
            "application/vnd.ms-excel" to "xls",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document" to "docx",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.template" to "dotx",
            "application/vnd.ms-word.document.macroenabled.12" to "docm",
            "application/vnd.ms-word.template.macroenabled.12" to "dotm",
            "application/vnd.oasis.opendocument.text" to "odt",
            "application/vnd.oasis.opendocument.text-template" to "ott",
            "application/vnd.openxmlformats-officedocument.presentationml.presentation" to "pptx",
            "application/vnd.openxmlformats-officedocument.presentationml.slideshow" to "ppsx",
            "application/vnd.openxmlformats-officedocument.presentationml.template" to "potx",
            "application/vnd.ms-powerpoint.presentation.macroenabled.12" to "pptm",
            "application/vnd.ms-powerpoint.slideshow.macroenabled.12" to "ppsm",
            "application/vnd.ms-powerpoint.template.macroenabled.12" to "potm",
            "application/vnd.oasis.opendocument.presentation" to "odp",
            "application/vnd.oasis.opendocument.presentation-template" to "otp",
            "application/vnd.ms-powerpoint" to "ppt",
            "application/wps-office.dps" to "dps",
            "application/rtf" to "rtf",
            "text/rtf" to "rtf",
            "application/msword" to "doc",
            "application/wps-office.wps" to "wps",
            "text/csv" to "csv",
            "text/comma-separated-values" to "csv",
            "application/csv" to "csv",
            "text/tab-separated-values" to "tsv",
            "application/vnd.oasis.opendocument.text-flat-xml" to "fodt",
            "application/vnd.oasis.opendocument.spreadsheet-flat-xml" to "fods",
            "application/vnd.oasis.opendocument.presentation-flat-xml" to "fodp",
            "application/zip" to "zip",
            "application/x-zip-compressed" to "zip",
            "application/gzip" to "gz",
            "application/x-gzip" to "gz",
            "application/x-tar" to "tar",
            "application/x-compressed-tar" to "tgz",
        )
    }

    /**
     * Times Android stopped the app for memory since the last call, newest
     * first. An editor holding a large workbook can be killed without a
     * crash report; these let Crashlytics count them. The first call after
     * install only records where to start.
     */
    @TargetApi(Build.VERSION_CODES.R)
    private fun recentMemoryExits(): List<Map<String, Any?>> {
        val prefs = getSharedPreferences("dochelper_diagnostics", MODE_PRIVATE)
        val since = prefs.getLong("lastExitReported", 0L)
        val manager = getSystemService(ActivityManager::class.java) ?: return emptyList()
        val exits = try {
            manager.getHistoricalProcessExitReasons(packageName, 0, 16)
        } catch (e: Exception) {
            return emptyList()
        }
        val newest = exits.maxOfOrNull { it.timestamp } ?: since
        prefs.edit().putLong("lastExitReported", maxOf(since, newest)).apply()
        if (since == 0L) return emptyList()
        return exits
            .filter { it.timestamp > since }
            .mapNotNull { exit ->
                val reason = when (exit.reason) {
                    ApplicationExitInfo.REASON_LOW_MEMORY -> "low_memory"
                    ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "excessive_resource_usage"
                    else -> return@mapNotNull null
                }
                mapOf(
                    "reason" to reason,
                    "timestamp" to exit.timestamp,
                    "pssKb" to exit.pss,
                    "rssKb" to exit.rss,
                    "foreground" to (exit.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND),
                    "description" to exit.description,
                )
            }
    }

    override fun onDestroy() {
        pdfIo.shutdown()
        super.onDestroy()
    }
}
