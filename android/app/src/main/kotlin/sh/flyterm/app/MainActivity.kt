package sh.flyterm.app

import android.content.Intent
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    // Tracks a `SystemSpeechPlugin.recognize` call in flight across the
    // async startActivityForResult / onActivityResult round trip. Must
    // never be silently overwritten by a second call — see the
    // "ALREADY_RUNNING" guard below for why.
    private var pendingSpeechResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MediaStorePlugin.CHANNEL)
            .setMethodCallHandler { call, result ->
                @Suppress("UNCHECKED_CAST")
                MediaStorePlugin.handle(
                    applicationContext,
                    call.method,
                    call.arguments as? Map<*, *>,
                    result,
                )
            }
        // Inline recognition against an explicitly chosen RecognitionService.
        // Two-way: Dart calls listServices/start/stop/cancel, and the plugin
        // pushes onStart/onResult/onError/onEndOfSpeech back over the same
        // channel.
        val inlineSpeechChannel =
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                InlineSpeechPlugin.CHANNEL,
            )
        val inlineSpeech = InlineSpeechPlugin(applicationContext, inlineSpeechChannel)
        inlineSpeechChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "listServices" -> result.success(inlineSpeech.listServices())
                "isAvailable" ->
                    result.success(
                        inlineSpeech.isServiceAvailable(call.argument<String>("component")),
                    )
                "start" -> {
                    inlineSpeech.start(
                        call.argument<String>("component"),
                        call.argument<String>("languageTag"),
                    )
                    result.success(true)
                }
                "stop" -> {
                    inlineSpeech.stop()
                    result.success(true)
                }
                "cancel" -> {
                    inlineSpeech.cancel()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SystemSpeechPlugin.CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isAvailable" -> result.success(SystemSpeechPlugin.isAvailable(this))
                    "recognize" -> {
                        if (pendingSpeechResult != null) {
                            // A recognition is already in flight. Overwriting
                            // pendingSpeechResult here would leave the earlier
                            // call's Dart-side Future pending forever (nothing
                            // would ever complete it) — refuse instead.
                            result.error(
                                "ALREADY_RUNNING",
                                "a recognize() call is already in flight",
                                null,
                            )
                        } else if (SystemSpeechPlugin.startRecognize(this)) {
                            pendingSpeechResult = result
                        } else {
                            // No handler for the intent, or starting it threw.
                            // This must NOT look like "user cancelled": the
                            // cancel case means the user saw a speech UI and
                            // dismissed it (feedback happened), whereas this
                            // means nothing appeared at all. Reporting both as
                            // null left the Dart side unable to tell them
                            // apart, so a failure to launch showed the user
                            // absolutely nothing.
                            result.error(
                                "START_FAILED",
                                "no activity handled ACTION_RECOGNIZE_SPEECH",
                                null,
                            )
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == SystemSpeechPlugin.REQUEST_CODE) {
            val pending = pendingSpeechResult
            pendingSpeechResult = null
            if (pending != null) {
                if (resultCode == RESULT_OK) {
                    pending.success(SystemSpeechPlugin.extractText(data))
                } else {
                    // User cancelled, or the recognizer activity reported
                    // failure — a normal, expected outcome, not an error.
                    pending.success(null)
                }
            }
            return
        }
        // Any other request code (permission_handler, file_picker's legacy
        // path, etc.) must keep flowing through the normal Flutter/AndroidX
        // dispatch chain — only intercept our own code above.
        super.onActivityResult(requestCode, resultCode, data)
    }
}
