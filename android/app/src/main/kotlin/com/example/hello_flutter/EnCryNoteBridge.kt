package com.example.hello_flutter

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.system.Os
import android.system.OsConstants
import io.flutter.plugin.common.BinaryMessenger
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
 * reported after all three. The previous generation is kept as the recovery
 * candidate for an interrupted replacement.
 */
class EnCryNoteBridge(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        private const val CHANNEL = "encrynote/platform"
        private val STAGED = "vault.next"
        private val ACTIVE = "vault.enc"
        private val PREVIOUS = "vault.previous"

        fun register(messenger: BinaryMessenger, context: Context) {
            val channel = MethodChannel(messenger, CHANNEL)
            channel.setMethodCallHandler(EnCryNoteBridge(context.applicationContext))
        }
    }

    // Filesystem work runs off the platform main thread.
    private val worker = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "encrynote-commit")
    }
    private val main = Handler(Looper.getMainLooper())

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "commitVault") {
            result.notImplemented()
            return
        }
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
                error.message ?: "commit.failed"
            } catch (error: Exception) {
                error.message ?: "commit.failed"
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
        val directory = context.filesDir.canonicalFile
        val staged = checkedPath(stagedPath, directory, STAGED)
        val active = checkedPath(activePath, directory, ACTIVE)
        val previous = checkedPath(previousPath, directory, PREVIOUS)

        if (!staged.isFile) throw CommitFailure("commit.staged")

        // Retire the current generation first; the active file still holds the
        // same bytes, so an interruption here never loses the only copy.
        if (active.exists() && !active.renameTo(previous)) {
            throw CommitFailure("commit.backup")
        }
        syncDirectory(active.parentFile!!)

        if (!staged.renameTo(active)) throw CommitFailure("commit.replace")
        syncFile(active)
        syncDirectory(active.parentFile!!)
    }

    /**
     * Resolves [path] and requires the fixed basename plus the OS-provided
     * private directory as its exact parent. Import/export locations are
     * outside that directory, so they can never become a commit target.
     */
    private fun checkedPath(path: String, base: File, expectedName: String): File {
        val file = File(path).canonicalFile
        if (file.name != expectedName) throw CommitFailure("commit.path")
        if (file.parentFile != base) throw CommitFailure("commit.path")
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
