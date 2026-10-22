package com.example.hello_flutter

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.system.Os
import android.system.OsConstants
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.RandomAccessFile
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

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setPrivacyShield" -> {
                if (call.arguments == true) installShield() else removeShield()
                result.success(null)
            }
            "commitVault" -> commitFrom(call, result)
            else -> result.notImplemented()
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
