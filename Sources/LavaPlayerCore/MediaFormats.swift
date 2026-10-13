import Foundation

/// What a player will offer to open, by extension.
///
/// mpv opens far more than this — it opens almost anything FFmpeg can probe —
/// so the list is not about what will *play*. It is about what a folder scan
/// treats as a neighbour and what the file dialog shows: a series folder full
/// of `.srt`, `.nfo` and `.jpg` posters should step from episode to episode,
/// not through the subtitles. Anything named outright on the command line or
/// dropped on the window is opened regardless.
public enum MediaFormats {
    public static let video: Set<String> = [
        "mkv", "mp4", "m4v", "webm", "avi", "mov", "wmv", "flv", "mpg", "mpeg",
        "ts", "m2ts", "mts", "ogv", "3gp", "vob", "divx", "asf", "rm", "rmvb",
    ]
    public static let audio: Set<String> = [
        "mp3", "flac", "ogg", "opus", "m4a", "aac", "wav", "wma", "ape", "alac",
        "mka", "wv",
    ]

    /// Text and bitmap subtitle files mpv reads. One of these dropped on the
    /// window is loaded into the video playing, not opened in its place.
    public static let subtitles: Set<String> = [
        "srt", "ass", "ssa", "vtt", "sub", "idx", "sup", "smi", "lrc",
    ]

    public static func isSubtitle(path: String) -> Bool {
        subtitles.contains((path as NSString).pathExtension.lowercased())
    }

    public static func isMedia(path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return video.contains(ext) || audio.contains(ext)
    }

    /// For `FileDialog`'s filter, which wants them without dots.
    public static var dialogExtensions: [String] {
        (video.union(audio)).sorted()
    }
}
