package com.yourmateapps.pdfhelper

import android.app.Activity
import android.app.Instrumentation
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import java.io.File
import java.io.IOException

/** Runs against the real MediaStore, without a test framework dependency. */
class PublicPdfExporterInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        start()
    }

    override fun onStart() {
        val tests = listOf(
            "downloadsPublication" to { publishesIn("Downloads", "Download/DocHelper/") },
            "documentsPublication" to { publishesIn("Documents", "Documents/DocHelper/") },
            "nameCollisionsPreserveBothDocuments" to ::preservesCollisions,
            "providerRenameDeleteAndLegacyRecovery" to ::mutatesProviderCopies,
            "staleUriCannotDeleteReplacementAtSamePath" to ::protectsReplacement,
            "invalidSourceAndNamesAreRejected" to ::rejectsInvalidInputs,
            "updateReplacesCopyWithoutTruncating" to ::updatesBySwappingRows,
            "staleUriAfterUpdateCannotReachReplacement" to ::protectsReplacementAfterUpdate,
            "updateOfMissingCopyChangesNothing" to ::refusesUpdateOfMissingCopy,
            "updateKeepsALongName" to ::updatesALongName,
        )
        var failed = 0
        for ((index, test) in tests.withIndex()) {
            val result = Bundle().apply {
                putString("class", this@PublicPdfExporterInstrumentation.javaClass.name)
                putString("test", test.first)
                putInt("current", index + 1)
                putInt("numtests", tests.size)
            }
            sendStatus(1, result)
            try {
                check(Build.VERSION.SDK_INT >= 29) { "Run these MediaStore checks on Android 10 or newer" }
                test.second()
                sendStatus(0, result)
            } catch (error: Throwable) {
                failed++
                result.putString("stack", error.stackTraceToString())
                sendStatus(-2, result)
            }
        }
        finish(Activity.RESULT_OK, Bundle().apply {
            putString("stream", "\nPublicPdfExporter: ${tests.size - failed} passed, $failed failed\n")
            if (failed != 0) putString("shortMsg", "$failed public export checks failed")
        })
    }

    private fun withFixture(block: (File, MutableList<Uri>) -> Unit) {
        val file = File.createTempFile("public-export-check-", ".pdf", targetContext.cacheDir)
        val published = mutableListOf<Uri>()
        try {
            file.writeBytes("%PDF-1.7\npublic exporter fixture\n%%EOF\n".toByteArray())
            block(file, published)
        } finally {
            for (uri in published) {
                check(targetContext.contentResolver.delete(uri, null, null) == 1) {
                    "Could not remove test fixture $uri"
                }
            }
            check(file.delete()) { "Could not remove local test fixture" }
        }
    }

    private fun publish(file: File, location: String, published: MutableList<Uri>): Map<String, String> {
        val result = PublicPdfExporter(targetContext).save(file.path, file.name, location)
        published.add(Uri.parse(result.getValue("uri")))
        assertPublishedMetadata(result)
        return result
    }

    @Suppress("DEPRECATION")
    private fun assertPublishedMetadata(result: Map<String, String>) {
        val uri = Uri.parse(result.getValue("uri"))
        targetContext.contentResolver.query(uri, arrayOf(
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.RELATIVE_PATH,
            MediaStore.MediaColumns.IS_PENDING,
        ), null, null, null)!!.use { row ->
            check(row.moveToFirst()) { "Published PDF is missing" }
            check(row.getString(0) == result.getValue("name")) {
                "Returned name differs from the final MediaStore name"
            }
            val publicPath = File(Environment.getExternalStorageDirectory(),
                File(row.getString(1), row.getString(0)).path).absolutePath
            check(publicPath == result.getValue("publicPath")) {
                "Returned path differs from the final MediaStore location"
            }
            check(row.getInt(2) == 0) { "Published PDF is still hidden by IS_PENDING" }
        }
    }

    private fun publishesIn(location: String, relativePath: String) = withFixture { file, published ->
        val result = publish(file, location, published)
        val resolver = targetContext.contentResolver
        val uri = published.single()
        check(resolver.openInputStream(uri)!!.use { it.readBytes() }.contentEquals(file.readBytes()))
        resolver.query(uri, arrayOf(
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.RELATIVE_PATH,
            MediaStore.MediaColumns.IS_PENDING,
        ), null, null, null)!!.use { row ->
            check(row.moveToFirst())
            check(row.getString(0) == result.getValue("name"))
            check(row.getString(1) == relativePath)
            check(row.getInt(2) == 0) { "Published PDF is still hidden by IS_PENDING" }
        }
        check(result.getValue("publicPath").endsWith("/$relativePath${result.getValue("name")}"))
        check(file.exists()) { "Export must preserve the native engine's working file" }
    }

    private fun preservesCollisions() = withFixture { file, published ->
        val original = file.readBytes()
        for (location in listOf("Downloads", "Documents")) {
            file.writeBytes(original)
            val first = publish(file, location, published)
            file.appendText("second export")
            val second = publish(file, location, published)
            check(first.getValue("uri") != second.getValue("uri"))
            check(first.getValue("name") != second.getValue("name")) {
                "Colliding PDFs returned the same name in $location: ${first.getValue("name")}"
            }
            check(first.getValue("publicPath") != second.getValue("publicPath"))
            // Check both records again after the second publication.
            assertPublishedMetadata(first)
            assertPublishedMetadata(second)
            check(targetContext.contentResolver.openInputStream(Uri.parse(first.getValue("uri")))!!
                .use { it.readBytes() }.contentEquals(original)) { "Existing PDF was overwritten" }
            check(targetContext.contentResolver.openInputStream(Uri.parse(second.getValue("uri")))!!
                .use { it.readBytes() }.contentEquals(file.readBytes()))
        }
    }

    private fun rejectsInvalidInputs() = withFixture { file, _ ->
        val exporter = PublicPdfExporter(targetContext)
        fun mustReject(block: () -> Unit) {
            var rejected = false
            try { block() } catch (_: IllegalArgumentException) { rejected = true }
            check(rejected) { "Invalid export request was accepted" }
        }
        mustReject { exporter.save("${file.path}.missing", file.name, "Downloads") }
        mustReject { exporter.save(file.path, "../escape.pdf", "Downloads") }
        mustReject { exporter.save(file.path, "..\\escape.pdf", "Documents") }
        mustReject { exporter.save(file.path, "", "Downloads") }
        mustReject { exporter.save(file.path, file.name, "Pictures") }
        file.writeBytes(byteArrayOf())
        mustReject { exporter.save(file.path, file.name, "Downloads") }
    }

    private fun mutatesProviderCopies() = withFixture { file, published ->
        val exporter = PublicPdfExporter(targetContext)
        for (location in listOf("Downloads", "Documents")) {
            val first = publish(file, location, published)
            val second = publish(file, location, published)
            val renamed = exporter.rename(first.getValue("uri"), first.getValue("publicPath"),
                "renamed-${file.name}")
            check(renamed.getValue("uri") == first.getValue("uri")) { "Rename changed the document identity" }
            check(renamed.getValue("name") == "renamed-${file.name}")
            assertPublishedMetadata(renamed)
            check(targetContext.contentResolver.openInputStream(Uri.parse(renamed.getValue("uri")))!!
                .use { it.readBytes() }.contentEquals(file.readBytes()))
            // Legacy records contain only the path. Recover their owned row
            // without requiring MANAGE_EXTERNAL_STORAGE.
            val legacy = exporter.rename(null, second.getValue("publicPath"), "legacy-${file.name}")
            assertPublishedMetadata(legacy)
            check(exporter.delete(null, legacy.getValue("publicPath")))
            published.remove(Uri.parse(second.getValue("uri")))
            check(exporter.delete(renamed.getValue("uri"), renamed.getValue("publicPath")))
            published.remove(Uri.parse(first.getValue("uri")))
            check(exporter.delete(renamed.getValue("uri"), renamed.getValue("publicPath"))) {
                "Deleting an already removed provider row should be idempotent"
            }
        }
    }

    private fun protectsReplacement() = withFixture { file, published ->
        val exporter = PublicPdfExporter(targetContext)
        val first = publish(file, "Downloads", published)
        check(exporter.delete(first.getValue("uri"), first.getValue("publicPath")))
        published.remove(Uri.parse(first.getValue("uri")))
        file.appendText("replacement document")
        val replacement = publish(file, "Downloads", published)
        check(replacement.getValue("publicPath") == first.getValue("publicPath"))
        check(exporter.delete(first.getValue("uri"), first.getValue("publicPath")))
        check(targetContext.contentResolver.openInputStream(Uri.parse(replacement.getValue("uri")))!!
            .use { it.readBytes() }.contentEquals(file.readBytes())) {
            "A stale URI deleted a different document at its old path"
        }
    }

    private fun content(uri: String): ByteArray =
        targetContext.contentResolver.openInputStream(Uri.parse(uri))!!.use { it.readBytes() }

    private fun rowExists(uri: String): Boolean =
        targetContext.contentResolver.query(Uri.parse(uri), arrayOf(MediaStore.MediaColumns._ID),
            null, null, null)?.use { it.moveToFirst() } ?: false

    /** How many of this app's rows are named [name]. */
    private fun rowsNamed(name: String): Int =
        targetContext.contentResolver.query(
            MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY),
            arrayOf(MediaStore.MediaColumns._ID),
            "${MediaStore.MediaColumns.DISPLAY_NAME} = ?", arrayOf(name), null,
        )!!.use { it.count }

    /** An update writes a new row and swaps it with the old one: the copy
     * keeps its name and folder, the old row and its "previous version" are
     * gone, and the URI the app keeps still reaches the copy afterwards. */
    private fun updatesBySwappingRows() = withFixture { file, published ->
        val exporter = PublicPdfExporter(targetContext)
        for (location in listOf("Downloads", "Documents")) {
            file.writeBytes("%PDF-1.7\nfirst version\n%%EOF\n".toByteArray())
            val first = publish(file, location, published)
            val kept = first.getValue("uri")
            file.writeBytes("%PDF-1.7\nsecond, longer version of the document\n%%EOF\n".toByteArray())
            val updated = exporter.update(kept, first.getValue("publicPath"), file.path)
            published.remove(Uri.parse(kept))
            published.add(Uri.parse(updated.getValue("uri")))
            assertPublishedMetadata(updated)
            check(updated.getValue("name") == first.getValue("name")) { "An update renamed the copy" }
            check(updated.getValue("publicPath") == first.getValue("publicPath")) { "An update moved the copy" }
            check(content(updated.getValue("uri")).contentEquals(file.readBytes())) {
                "The update did not write the new content"
            }
            check(!rowExists(kept)) { "The replaced row was left behind" }
            val base = first.getValue("name").substringBeforeLast('.')
            check(rowsNamed("$base (previous version).pdf") == 0) { "The previous version was left behind" }

            // The app still sends the URI the copy was first saved with.
            file.writeBytes("%PDF-1.7\nthird\n%%EOF\n".toByteArray())
            val again = exporter.update(kept, first.getValue("publicPath"), file.path)
            published.remove(Uri.parse(updated.getValue("uri")))
            published.add(Uri.parse(again.getValue("uri")))
            assertPublishedMetadata(again)
            check(again.getValue("publicPath") == first.getValue("publicPath"))
            check(content(again.getValue("uri")).contentEquals(file.readBytes())) {
                "A second update through the kept URI did not reach the copy"
            }
            check(!rowExists(updated.getValue("uri")))
            val renamed = exporter.rename(kept, first.getValue("publicPath"), "renamed-${file.name}")
            check(renamed.getValue("uri") == again.getValue("uri")) { "Rename through the kept URI missed the copy" }
            assertPublishedMetadata(renamed)
            check(exporter.delete(kept, renamed.getValue("publicPath")))
            published.remove(Uri.parse(again.getValue("uri")))
            check(!rowExists(again.getValue("uri"))) { "Delete through the kept URI missed the copy" }
        }
    }

    private fun protectsReplacementAfterUpdate() = withFixture { file, published ->
        val exporter = PublicPdfExporter(targetContext)
        val first = publish(file, "Downloads", published)
        val kept = first.getValue("uri")
        file.appendText("edited")
        val updated = exporter.update(kept, first.getValue("publicPath"), file.path)
        published.remove(Uri.parse(kept))
        check(exporter.delete(kept, first.getValue("publicPath")))
        check(!rowExists(updated.getValue("uri")))
        file.appendText("a different document")
        val replacement = publish(file, "Downloads", published)
        check(replacement.getValue("publicPath") == first.getValue("publicPath"))
        check(exporter.delete(kept, first.getValue("publicPath")))
        var refused = false
        try { exporter.update(kept, first.getValue("publicPath"), file.path) } catch (_: IOException) { refused = true }
        check(refused) { "An update through a deleted copy's URI was accepted" }
        check(rowExists(replacement.getValue("uri")) &&
            content(replacement.getValue("uri")).contentEquals(file.readBytes())) {
            "A stale URI reached a different document at its old path"
        }
    }

    private fun refusesUpdateOfMissingCopy() = withFixture { file, published ->
        val exporter = PublicPdfExporter(targetContext)
        val first = publish(file, "Downloads", published)
        check(exporter.delete(first.getValue("uri"), first.getValue("publicPath")))
        published.remove(Uri.parse(first.getValue("uri")))
        var refused = false
        try {
            exporter.update(first.getValue("uri"), first.getValue("publicPath"), file.path)
        } catch (_: IOException) {
            refused = true
        }
        check(refused) { "Updating a deleted copy was accepted" }
        check(rowsNamed(first.getValue("name")) == 0) { "A failed update left a new row behind" }
    }

    /** A name close to the 255-byte limit is still updated: the old copy's
     * "previous version" name is shortened to fit beside it. */
    private fun updatesALongName() = withFixture { file, published ->
        val exporter = PublicPdfExporter(targetContext)
        // 80 Devanagari letters take 240 bytes, ".pdf" four more.
        val longName = 0x915.toChar().toString().repeat(80) + ".pdf"
        val first = exporter.save(file.path, longName, "Downloads")
        published.add(Uri.parse(first.getValue("uri")))
        assertPublishedMetadata(first)
        file.appendText("edited")
        val updated = exporter.update(first.getValue("uri"), first.getValue("publicPath"), file.path)
        published.remove(Uri.parse(first.getValue("uri")))
        published.add(Uri.parse(updated.getValue("uri")))
        assertPublishedMetadata(updated)
        check(updated.getValue("name") == first.getValue("name")) { "An update renamed a long-named copy" }
        check(content(updated.getValue("uri")).contentEquals(file.readBytes())) {
            "The update of a long-named copy did not write the new content"
        }
    }
}
