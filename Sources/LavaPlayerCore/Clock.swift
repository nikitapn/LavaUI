/// Times as a player shows them.
public enum Clock {
    /// `4:05`, `1:02:03`; `--:--` for a time nobody knows yet (a stream that
    /// has not reported its length). Hours appear only when needed, and then
    /// minutes are always two digits, which is how every player writes it.
    public static func format(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "--:--" }
        let whole = Int(max(0, seconds).rounded(.down))
        let h = whole / 3600, m = (whole / 60) % 60, s = whole % 60
        if h > 0 { return "\(h):\(pad(m)):\(pad(s))" }
        return "\(m):\(pad(s))"
    }

    /// Both ends of the readout in the same shape, so that `0:07 / 1:02:03`
    /// does not become `0:00:07 / 1:02:03` the moment hours appear — it is
    /// written that way from the start, and the label never changes width
    /// within one file.
    public static func pair(position: Double?, duration: Double?) -> String {
        let long = (duration ?? 0) >= 3600
        return "\(format(position, hours: long)) / \(format(duration))"
    }

    static func format(_ seconds: Double?, hours: Bool) -> String {
        guard hours, let seconds, seconds.isFinite else { return format(seconds) }
        let whole = Int(max(0, seconds).rounded(.down))
        return "\(whole / 3600):\(pad((whole / 60) % 60)):\(pad(whole % 60))"
    }

    private static func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
