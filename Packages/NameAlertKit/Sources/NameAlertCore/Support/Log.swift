import os

/// Entry point for logging. Transcript text may only be logged at `.debug` with `privacy: .private`.
public enum Log {
    public static func logger(_ category: String) -> Logger {
        Logger(subsystem: "dev.balakumar.namealert", category: category)
    }
}
