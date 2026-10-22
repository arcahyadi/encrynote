package com.example.hello_flutter

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.system.Os
import android.system.OsConstants
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.RandomAccessFile
import java.util.UUID
import java.util.concurrent.Executors

/**
 * Replaces the vault on disk with an explicit commit point.
 *
 * Commit point: the staged ciphertext is renamed over the active file, the new
 * active file is fsynced, and the parent directory is fsynced. Success is only
 * reported after all three.
 *
 * Failure semantics: any failure after the active file was moved puts the
 * previous generation back, so a failed commit leaves the old vault active and
 * a caller that reports "not saved" tells the truth. If that rollback itself
 * fails, the active generation is genuinely unknown and the call reports
 * `commit.uncertain` rather than claiming either outcome.
 *
 * It also owns the privacy shield and the window-focus stream. The shield is
 * installed from the activity callbacks before the system can snapshot the
 * window; only Flutter removes it, after its own deadline and frame checks.
 *
 * File transfer is delegated to the system document UI. A pick stores only the
 * content URI for the current selection; reading streams that URI with a byte
 * bound, and nothing in this class accepts a caller-supplied path or caches the
 * plaintext afterwards.
 */
class EnCryNoteBridge private constructor(
    private val activity: FlutterActivity,
    private val context: Context,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        private const val CHANNEL = "encrynote/platform"
        private const val FOCUS_CHANNEL = "encrynote/focus"
        private const val STAGED = "vault.next"
        private const val ACTIVE = "vault.enc"
        private const val PREVIOUS = "vault.previous"

        private const val PICK_IMPORT = 4701
        private const val SAVE_EXPORT = 4702

        fun register(messenger: BinaryMessenger, activity: FlutterActivity): EnCryNoteBridge {
            val bridge = EnCryNoteBridge(activity, activity.applicationContext)
            MethodChannel(messenger, CHANNEL).setMethodCallHandler(bridge)
            EventChannel(messenger, FOCUS_CHANNEL).setStreamHandler(bridge)
            return bridge
        }
    }

    // Filesystem work runs off the platform main thread.
    private val worker = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "encrynote-commit")
    }
    private val main = Handler(Looper.getMainLooper())
    private var shieldVisible = false
    private var focusSink: EventChannel.EventSink? = null

    /** The grant for the selection the picker last returned; a URI, not a path. */
    private var importGrant: Uri? = null

    /** The opaque handle that names [importGrant]; any other token is refused. */
    private var importToken: String? = null
    private var pickResult: MethodChannel.Result? = null
    private var saveResult: MethodChannel.Result? = null
    private var pendingExport: ByteArray? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setPrivacyShield" -> {
                if (call.arguments == true) installShield() else removeShield()
                result.success(null)
            }
            "commitVault" -> commitFrom(call, result)
            "pickImport" -> pickImport(result)
            "readImport" -> readImport(call, result)
            "releaseImport" -> {
                releaseImport(call.arguments as? String)
                result.success(null)
            }
            "saveExport" -> saveExport(call, result)
            else -> result.notImplemented()
        }
    }

    // --- document picker -----------------------------------------------------

    private fun pickImport(result: MethodChannel.Result) {
        if (pickResult != null) {
            result.error("busy", "pick.pending", null)
            return
        }
        pickResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            // Only the two shapes import accepts; the app never browses files.
            type = "*/*"
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf("text/markdown", "text/plain", "application/octet-stream"),
            )
            // Keep the document where it is: no copy, no local-only move.
            putExtra(Intent.EXTRA_LOCAL_ONLY, true)
        }
        try {
            activity.startActivityForResult(intent, PICK_IMPORT)
        } catch (error: Exception) {
            pickResult = null
            result.error("storage", "pick.launch", null)
        }
    }

    /** Called from the activity's `onActivityResult`. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        when (requestCode) {
            PICK_IMPORT -> {
                val result = pickResult ?: return true
                pickResult = null
                val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
                if (uri == null) {
                    result.success(null)
                    return true
                }
                // Only the temporary grant the picker itself handed us: no
                // persistable permission and no bookmark, so the access cannot
                // outlive this process.
                releaseImport(null)
                val token = UUID.randomUUID().toString()
                importGrant = uri
                importToken = token
                result.success(
                    mapOf(
                        "token" to token,
                        "name" to (displayName(uri) ?: "import.md"),
                        "length" to knownLength(uri),
                    ),
                )
                return true
            }
            SAVE_EXPORT -> {
                val result = saveResult ?: return true
                saveResult = null
                val bytes = pendingExport
                pendingExport = null
                val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
                if (uri == null || bytes == null) {
                    result.success(false)
                    return true
                }
                worker.execute {
                    val outcome = try {
                        context.contentResolver.openOutputStream(uri, "wt")?.use { out ->
                            out.write(bytes)
                            out.flush()
                        } ?: throw IllegalStateException("save.stream")
                        null
                    } catch (error: Exception) {
                        "save.write"
                    }
                    main.post {
                        if (outcome == null) result.success(true)
                        else result.error("storage", outcome, null)
                    }
                }
                return true
            }
        }
        return false
    }

    private fun displayName(uri: Uri): String? = try {
        context.contentResolver.query(
            uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        }
    } catch (_: Exception) {
        null
    }

    private fun knownLength(uri: Uri): Long? = try {
        context.contentResolver.query(
            uri, arrayOf(OpenableColumns.SIZE), null, null, null,
        )?.use { cursor ->
            if (cursor.moveToFirst() && !cursor.isNull(0)) cursor.getLong(0) else null
        }
    } catch (_: Exception) {
        null
    }

    /**
     * Streams the picked document, refusing more than [maxBytes] even when the
     * provider reports no size: the bound is enforced on the bytes actually
     * read, never on metadata alone.
     */
    private fun readImport(call: MethodCall, result: MethodChannel.Result) {
        val token = call.argument<String>("token")
        val maxBytes = call.argument<Int>("maxBytes")
        if (token == null || maxBytes == null || maxBytes <= 0) {
            result.error("format", "read.arguments", null)
            return
        }
        val uri = importGrant
        // The token must name the selection this bridge actually handed out;
        // no path and no guessed token can reach a file.
        if (uri == null || token != importToken) {
            result.error("storage", "read.grant", null)
            return
        }
        worker.execute {
            val outcome: Pair<ByteArray?, String?> = try {
                Pair(readBounded(uri, maxBytes), null)
            } catch (error: TooLarge) {
                Pair(null, "limit")
            } catch (error: Exception) {
                Pair(null, "read.stream")
            }
            main.post {
                val bytes = outcome.first
                if (bytes != null) result.success(bytes)
                else result.error(outcome.second ?: "read.stream", "read", null)
            }
        }
    }

    private class TooLarge : Exception()

    private fun readBounded(uri: Uri, maxBytes: Int): ByteArray {
        val out = ByteArrayOutputStream()
        context.contentResolver.openInputStream(uri)?.use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                if (out.size() + read > maxBytes) throw TooLarge()
                out.write(buffer, 0, read)
            }
        } ?: throw IllegalStateException("read.stream")
        return out.toByteArray()
    }

    private fun releaseImport(token: String?) {
        // Only the current grant can be dropped; a stale token is a no-op.
        if (token != null && token != importToken) return
        importGrant = null
        importToken = null
    }

    private fun saveExport(call: MethodCall, result: MethodChannel.Result) {
        if (saveResult != null) {
            result.error("busy", "save.pending", null)
            return
        }
        val bytes = call.argument<ByteArray>("bytes")
        val fileName = call.argument<String>("fileName")
        if (bytes == null || fileName == null || fileName.contains('/')) {
            result.error("format", "save.arguments", null)
            return
        }
        saveResult = result
        pendingExport = bytes
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/octet-stream"
            putExtra(Intent.EXTRA_TITLE, fileName)
        }
        try {
            activity.startActivityForResult(intent, SAVE_EXPORT)
        } catch (error: Exception) {
            saveResult = null
            pendingExport = null
            result.error("storage", "save.launch", null)
        }
    }


    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        focusSink = events
    }

    override fun onCancel(arguments: Any?) {
        focusSink = null
    }

    /** Called on the platform thread before the window is paused or blurred. */
    fun onWindowFocusChanged(focused: Boolean) {
        if (!focused) installShield()
        focusSink?.success(focused)
    }

    fun onPause() = installShield()

    fun onResume() = focusSink?.success(true)

    /**
     * Opaque at the window level, so no stale note frame reaches the app
     * switcher.
     *
     * A Flutter view is a SurfaceView, so a plain view added on top would not
     * cover it: the surface is composited separately and punches through. The
     * window flag makes the system snapshot and any capture opaque instead, and
     * on Android 13+ the recents screenshot is disabled as well. Both are only
     * active while shielded, so a screenshot of the open app still works.
     */
    private fun installShield() {
        if (shieldVisible) return
        shieldVisible = true
        activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.setRecentsScreenshotEnabled(false)
        }
    }

    private fun removeShield() {
        if (!shieldVisible) return
        shieldVisible = false
        activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.setRecentsScreenshotEnabled(true)
        }
    }

    private fun commitFrom(call: MethodCall, result: MethodChannel.Result) {
        val stagedPath = call.argument<String>("stagedPath")
        val activePath = call.argument<String>("activePath")
        val previousPath = call.argument<String>("previousPath")
        if (stagedPath == null || activePath == null || previousPath == null) {
            result.error("storage", "commit.arguments", null)
            return
        }
        worker.execute {
            val outcome = try {
                commit(stagedPath, activePath, previousPath)
                null
            } catch (error: CommitFailure) {
                error.message ?: "commit.uncertain"
            } catch (error: Exception) {
                "commit.uncertain"
            }
            // A MethodChannel result must be delivered on the platform thread.
            main.post {
                if (outcome == null) result.success(null)
                else result.error("storage", outcome, null)
            }
        }
    }

    private class CommitFailure(message: String) : Exception(message)

    private fun commit(stagedPath: String, activePath: String, previousPath: String) {
        val root = context.filesDir.canonicalFile
        val staged = checkedPath(stagedPath, root, STAGED)
        val active = checkedPath(activePath, root, ACTIVE)
        val previous = checkedPath(previousPath, root, PREVIOUS)

        // All three must share one parent; the vault is one directory, not a set
        // of files that may be split across directories.
        val parent = active.parentFile!!
        if (staged.parentFile != parent || previous.parentFile != parent) {
            throw CommitFailure("commit.path")
        }
        if (!staged.isFile) throw CommitFailure("commit.staged")

        val hadActive = active.exists()
        if (hadActive && !active.renameTo(previous)) {
            throw CommitFailure("commit.backup")
        }

        try {
            syncDirectory(parent)
            if (!staged.renameTo(active)) throw CommitFailure("commit.replace")
            syncFile(active)
            syncDirectory(parent)
        } catch (error: Exception) {
            val failure = error as? CommitFailure ?: CommitFailure("commit.sync")
            rollback(staged, active, previous, hadActive)
            throw failure
        }
    }

    /**
     * Restores the previous generation after a failed commit. Leaving the new
     * generation active would make a reported failure a lie, and for a password
     * change it would leave the on-disk credentials different from the ones the
     * caller believes are active.
     */
    private fun rollback(staged: File, active: File, previous: File, hadActive: Boolean) {
        if (active.exists() && !active.renameTo(staged)) {
            throw CommitFailure("commit.uncertain")
        }
        if (hadActive && !previous.renameTo(active)) {
            throw CommitFailure("commit.uncertain")
        }
        // Best effort: if this sync fails the old bytes are still active, which
        // is the state the caller reports.
        try {
            syncDirectory(active.parentFile!!)
        } catch (_: Exception) {
        }
    }

    /**
     * Resolves [path] and requires the fixed basename plus a canonical parent
     * that is the private root or a directory inside it. Import/export
     * locations are outside that root, and a symlink that resolves outside it
     * is rejected, so neither can become a commit target.
     */
    private fun checkedPath(path: String, root: File, expectedName: String): File {
        val file = File(path).canonicalFile
        if (file.name != expectedName) throw CommitFailure("commit.path")
        val parent = file.parentFile ?: throw CommitFailure("commit.path")
        val inside = parent == root || parent.path.startsWith(root.path + File.separator)
        if (!inside) throw CommitFailure("commit.path")
        return file
    }

    private fun syncFile(file: File) {
        RandomAccessFile(file, "r").use { it.fd.sync() }
    }

    /** Makes the rename itself durable; not every filesystem honours this. */
    private fun syncDirectory(directory: File) {
        val fd = Os.open(directory.path, OsConstants.O_RDONLY, 0)
        try {
            Os.fsync(fd)
        } finally {
            Os.close(fd)
        }
    }
}
