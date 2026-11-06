package sh.flyterm.app

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognitionService
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.plugin.common.MethodChannel

/**
 * Inline speech recognition bound to an *explicitly chosen*
 * `RecognitionService`.
 *
 * ## Why this exists alongside `speech_to_text`
 *
 * `speech_to_text` can only bind two things: the system default
 * (`Settings.Secure.VOICE_RECOGNITION_SERVICE`) or, with its `intentLookup`
 * option, whatever `queryIntentServices` happens to return first:
 *
 * ```kotlin
 * // SpeechToTextPlugin.kt, findComponentName()
 * return list.firstOrNull()?.serviceInfo?.let { ComponentName(it.packageName, it.name) }
 * ```
 *
 * `firstOrNull()` — no filtering, no preference. On a ROM where the vendor
 * ships a `RecognitionService` that accepts a bind and then immediately fails
 * (`ERROR_CLIENT` within milliseconds), and where that stub happens to sort
 * first, *both* of those options bind the exact same broken service. A working
 * service sitting second in the list is unreachable.
 *
 * This plugin closes that gap: it enumerates the services and can bind any one
 * of them by [ComponentName], so the Dart side can walk the list until one
 * actually runs.
 *
 * ## Scope
 *
 * Deliberately final-results-only. The app's voice flow ignores partial
 * results (recognized text is filled into the input field for review, never
 * auto-sent), so streaming would be plumbing with no consumer.
 */
class InlineSpeechPlugin(
    private val context: Context,
    private val channel: MethodChannel,
) {
    companion object {
        const val CHANNEL = "sh.flyterm.app/inline_speech"
    }

    private val main = Handler(Looper.getMainLooper())
    private var recognizer: SpeechRecognizer? = null

    /**
     * Guards against a stale listener from a previous session reporting into
     * the current one. Every callback compares against this; a mismatch means
     * the session was superseded and the event is dropped.
     */
    private var session = 0

    /** "pkg/cls" of every installed `RecognitionService`. */
    fun listServices(): List<String> =
        context.packageManager
            .queryIntentServices(Intent(RecognitionService.SERVICE_INTERFACE), 0)
            .mapNotNull { it.serviceInfo }
            .map { "${it.packageName}/${it.name}" }

    /**
     * Whether [component] can be bound at all.
     *
     * Note this only reports that *something* is registered under that name —
     * the failure mode this whole plugin exists for is a service that binds
     * fine and then refuses to run, which no static check can predict. The
     * only real test is starting a session.
     */
    fun isServiceAvailable(component: String?): Boolean =
        if (component == null) {
            SpeechRecognizer.isRecognitionAvailable(context)
        } else {
            listServices().contains(component)
        }

    /**
     * Starts recognition on [component] (or the system default when null).
     *
     * Always tears down any previous recognizer first: unlike
     * `speech_to_text`, which skips recreation unless its `onDevice` flag
     * changed and so silently reuses a dead recognizer, switching target here
     * must actually switch target.
     */
    fun start(component: String?, languageTag: String?) {
        main.post {
            destroyLocked()
            val id = ++session
            val target = component?.let { parseComponent(it) }
            val rec =
                try {
                    if (target != null) {
                        SpeechRecognizer.createSpeechRecognizer(context, target)
                    } else {
                        SpeechRecognizer.createSpeechRecognizer(context)
                    }
                } catch (e: Exception) {
                    emit("onError", mapOf("session" to id, "error" to "create_failed: ${e.message}"))
                    return@post
                }
            if (rec == null) {
                emit("onError", mapOf("session" to id, "error" to "create_returned_null"))
                return@post
            }
            recognizer = rec
            rec.setRecognitionListener(listenerFor(id))
            try {
                rec.startListening(buildIntent(languageTag))
                emit("onStart", mapOf("session" to id))
            } catch (e: Exception) {
                emit("onError", mapOf("session" to id, "error" to "start_failed: ${e.message}"))
            }
        }
    }

    fun stop() {
        main.post {
            // stopListening keeps the recognizer alive so a final result can
            // still arrive; cancel/destroy would discard it.
            try {
                recognizer?.stopListening()
            } catch (_: Exception) {
            }
        }
    }

    fun cancel() {
        main.post {
            session++
            destroyLocked()
        }
    }

    private fun destroyLocked() {
        try {
            recognizer?.cancel()
            recognizer?.destroy()
        } catch (_: Exception) {
        }
        recognizer = null
    }

    private fun parseComponent(value: String): ComponentName? {
        val parts = value.split('/', limit = 2)
        return if (parts.size == 2) ComponentName(parts[0], parts[1]) else null
    }

    private fun buildIntent(languageTag: String?): Intent =
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
            )
            // Required by several recognizer implementations; omitting it is a
            // known cause of an immediate ERROR_CLIENT.
            putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, context.packageName)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, false)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            if (languageTag != null) {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, languageTag)
            }
        }

    private fun emit(method: String, args: Map<String, Any?>) {
        main.post { channel.invokeMethod(method, args) }
    }

    private fun listenerFor(id: Int) =
        object : RecognitionListener {
            override fun onResults(results: Bundle?) {
                if (id != session) return
                val text =
                    results
                        ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                        ?.firstOrNull()
                emit("onResult", mapOf("session" to id, "text" to text))
            }

            override fun onError(error: Int) {
                if (id != session) return
                emit("onError", mapOf("session" to id, "error" to errorName(error)))
            }

            override fun onEndOfSpeech() {
                if (id != session) return
                emit("onEndOfSpeech", mapOf("session" to id))
            }

            override fun onReadyForSpeech(params: Bundle?) {}

            override fun onBeginningOfSpeech() {}

            override fun onRmsChanged(rmsdB: Float) {}

            override fun onBufferReceived(buffer: ByteArray?) {}

            override fun onPartialResults(partialResults: Bundle?) {}

            override fun onEvent(eventType: Int, params: Bundle?) {}
        }

    /**
     * Same spellings `speech_to_text` uses, so `VoiceInputService`'s existing
     * error classification and the diagnostics read identically no matter
     * which backend produced them.
     */
    private fun errorName(code: Int): String =
        when (code) {
            SpeechRecognizer.ERROR_AUDIO -> "error_audio_error"
            SpeechRecognizer.ERROR_CLIENT -> "error_client"
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "error_permission"
            SpeechRecognizer.ERROR_NETWORK -> "error_network"
            SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "error_network_timeout"
            SpeechRecognizer.ERROR_NO_MATCH -> "error_no_match"
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "error_busy"
            SpeechRecognizer.ERROR_SERVER -> "error_server"
            SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "error_speech_timeout"
            SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED -> "error_language_not_supported"
            SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> "error_language_unavailable"
            SpeechRecognizer.ERROR_SERVER_DISCONNECTED -> "error_server_disconnected"
            SpeechRecognizer.ERROR_TOO_MANY_REQUESTS -> "error_too_many_requests"
            else -> "error_unknown ($code)"
        }
}
