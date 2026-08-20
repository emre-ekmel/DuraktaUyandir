package com.durakta.uyandir

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Alarm-app behavior: when the full-screen ringing notification fires
        // (FSI delivers to this activity with the alarm payload), the Ring UI
        // must present OVER the lock screen and wake the display. These are
        // the play-store-compliant replacements for the deprecated
        // FLAG_SHOW_WHEN_LOCKED/FLAG_TURN_SCREEN_ON window flags.
        if (android.os.Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
    }
}
