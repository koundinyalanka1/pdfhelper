package com.yourmateapps.pdfhelper

import android.content.Intent
import android.Manifest
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
                            require(source != null && name != null && location != null) { "Missing save details" }
                            pdfIo.execute {
                                try {
                                    val saved = PublicPdfExporter(applicationContext).save(source, name, location, mimeType)
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

    /** PDFs must look like PDFs and Office packages like ZIP archives.
     * Text and CSV have no signature; their engines read any bytes. */
    private fun requireDocumentContent(extension: String, header: ByteArray) {
        if (extension == "pdf") requirePdfHeader(header)
        if (extension in ZIP_EXTENSIONS) {
            require(header.size >= 4 && header[0] == 'P'.code.toByte() && header[1] == 'K'.code.toByte()) {
                "The selected document is not an Office document"
            }
        }
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

    private fun readHeader(input: java.io.InputStream): ByteArray {
        val bytes = ByteArray(1024)
        var count = 0
        while (count < bytes.size) {
            val read = input.read(bytes, count, bytes.size - count)
            if (read < 0) break
            count += read
        }
        return bytes.copyOf(count)
    }

    private fun requirePdfHeader(header: ByteArray) {
        require(String(header, Charsets.ISO_8859_1).contains("%PDF-")) {
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
        val extension = documentExtension(fileName, mimeType ?: intent?.type)
            ?: throw IllegalArgumentException("DocHelper cannot open this kind of file")
        // Display names are untrusted provider input, never path components.
        var safeName = (fileName ?: "opened.$extension")
            .replace(Regex("[\\\\/\\p{Cntrl}]"), "_").take(60)
        if (!safeName.endsWith(".$extension", ignoreCase = true)) safeName += ".$extension"
        val directory = File(cacheDir, "opened_documents").apply { mkdirs() }
        val tempFile = File.createTempFile("intent_", "_$safeName", directory)
        try {
            val input = contentResolver.openInputStream(uri)
                ?: throw IllegalArgumentException("The document provider returned no data")
            input.use {
                val header = readHeader(it)
                requireDocumentContent(extension, header)
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
            }
            return tempFile.absolutePath
        } catch (e: Exception) {
            tempFile.delete()
            throw e
        }
    }

    companion object {
        /** Extensions DocHelper opens from other apps. */
        private val OPENABLE_EXTENSIONS = setOf(
            "pdf", "txt", "text", "log", "md", "markdown", "json",
            "xlsx", "xlsm", "xltx", "xltm", "ods", "ots", "csv", "tsv",
            "docx", "docm", "dotx", "dotm", "odt", "ott", "rtf",
            "pptx", "pptm", "ppsx", "ppsm", "potx", "potm",
        )

        /** Formats that are ZIP packages, which must start like one. */
        private val ZIP_EXTENSIONS = setOf(
            "xlsx", "xlsm", "xltx", "xltm", "ods", "ots",
            "docx", "docm", "dotx", "dotm", "odt", "ott",
            "pptx", "pptm", "ppsx", "ppsm", "potx", "potm",
        )

        private val MIME_EXTENSIONS = mapOf(
            "application/pdf" to "pdf",
            "text/plain" to "txt",
            "text/markdown" to "md",
            "text/x-markdown" to "md",
            "application/json" to "json",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" to "xlsx",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.template" to "xltx",
            "application/vnd.ms-excel.sheet.macroenabled.12" to "xlsm",
            "application/vnd.oasis.opendocument.spreadsheet" to "ods",
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
            "application/rtf" to "rtf",
            "text/rtf" to "rtf",
            "text/csv" to "csv",
            "text/comma-separated-values" to "csv",
            "application/csv" to "csv",
            "text/tab-separated-values" to "tsv",
        )
    }

    override fun onDestroy() {
        pdfIo.shutdown()
        super.onDestroy()
    }
}
