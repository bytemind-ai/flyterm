package sh.flyterm.app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.speech.RecognizerIntent

/**
 * Fallback voice-input path, independent of the bound `SpeechRecognizer`
 * service that `speech_to_text` (the Flutter plugin) relies on.
 *
 * `speech_to_text` binds to a system `RecognitionService`. On ROMs that
 * ship no such bindable service (common on devices without Google speech
 * services), that path reports unavailable — but the device may still
 * have its own voice assistant or keyboard that answers
 * [RecognizerIntent.ACTION_RECOGNIZE_SPEECH], a *different* mechanism:
 * it starts a system speech UI via `startActivityForResult` rather than
 * binding a service, so a different set of ROM components can serve it.
 *
 * Wiring lives in [MainActivity] (channel `CHANNEL`, methods
 * `isAvailable` / `recognize`) because starting an activity for a result
 * requires an `Activity`, not just a `Context`.
 */
object SystemSpeechPlugin {
    const val CHANNEL = "sh.flyterm.app/system_speech"

    // Below 0x10000: androidx's modern Activity Result API (used by
    // e.g. file_picker's SAF path) generates its own request codes at or
    // above that value specifically to avoid colliding with legacy
    // startActivityForResult codes like this one. No other dependency in
    // this app calls startActivityForResult directly, so this fixed code
    // is not expected to collide with anything.
    const val REQUEST_CODE = 9273

    private fun recognizeIntent(): Intent =
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
            )
        }

    /**
     * Whether some activity on this device can handle
     * [RecognizerIntent.ACTION_RECOGNIZE_SPEECH].
     *
     * `resolveActivity` is itself subject to Android 11+ package
     * visibility: without a matching `<queries>` entry in the manifest it
     * returns null even when a matching activity is installed. The
     * `<queries>` entry for this intent lives in `AndroidManifest.xml`
     * alongside (but separate from) the one already there for
     * `android.speech.RecognitionService` — that one covers the bound
     * service `speech_to_text` uses, not this intent.
     */
    fun isAvailable(context: Context): Boolean {
        return recognizeIntent().resolveActivity(context.packageManager) != null
    }

    /**
     * Starts the system speech-recognition UI. Returns false if no
     * activity can handle the intent (checked again here, not just by the
     * caller, in case `isAvailable` and this call race against the device
     * state) or if starting it throws.
     *
     * Does not itself track the result — the caller ([MainActivity]) owns
     * the pending [io.flutter.plugin.common.MethodChannel.Result] across
     * the async round trip to `onActivityResult`.
     */
    fun startRecognize(activity: Activity): Boolean {
        if (!isAvailable(activity)) return false
        return try {
            activity.startActivityForResult(recognizeIntent(), REQUEST_CODE)
            true
        } catch (e: Exception) {
            false
        }
    }

    /** Extracts the top recognition candidate from an `onActivityResult` payload. */
    fun extractText(data: Intent?): String? {
        val results = data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
        return results?.firstOrNull()
    }
}
