import LavaUI

/// The keyboard, as mpv's defaults have taught everyone to expect it.
enum PlayerKeys {
    private enum Extra {
        static let comma: Int32 = 44
        static let period: Int32 = 46
        static let nine: Int32 = 57
        static let zero: Int32 = 48
        static let three: Int32 = 51
    }

    static func handle(_ event: KeyEvent, session: PlayerSession) -> Bool {
        switch event.key {
        case KeyCode.space:
            session.togglePause()
        case KeyCode.p where !event.control:
            session.togglePause()
        // Five seconds, or a minute with Shift — mpv's two steps.
        case KeyCode.right:
            session.seek(by: event.shift ? 60 : 5)
        case KeyCode.left:
            session.seek(by: event.shift ? -60 : -5)
        case KeyCode.up:
            session.nudgeVolume(5)
        case KeyCode.down:
            session.nudgeVolume(-5)
        case Extra.zero:
            session.nudgeVolume(5)
        case Extra.nine:
            session.nudgeVolume(-5)
        case KeyCode.m:
            session.toggleMute()
        // Subtitles: `j` the next track (`J` the one before), `v` show or
        // hide, `z`/`x` earlier/later by 100 ms. `#` (Shift+3) the next audio
        // track. All mpv's.
        case KeyCode.j:
            session.cycleSubtitles(backwards: event.shift)
        case KeyCode.v:
            session.toggleSubtitlesVisible()
        case KeyCode.z:
            session.nudgeSubtitleDelay(-0.1)
        case KeyCode.x:
            session.nudgeSubtitleDelay(0.1)
        case Extra.three where event.shift:
            session.cycleAudio()
        case Extra.period:
            session.stepFrame(1)
        case Extra.comma:
            session.stepFrame(-1)
        case KeyCode.f, KeyCode.enter:
            session.toggleFullscreen()
        case KeyCode.escape:
            session.leaveFullscreen()
        case KeyCode.n where !event.control, KeyCode.pageDown:
            session.step(1)
        case KeyCode.p where event.control, KeyCode.pageUp:
            session.step(-1)
        case KeyCode.o where event.control:
            session.openDialog()
        default:
            return false
        }
        session.noteActivity()
        return true
    }
}
