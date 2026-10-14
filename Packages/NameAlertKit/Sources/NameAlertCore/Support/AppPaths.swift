import Foundation

/// Where Takeheed keeps its files. In the sandbox this resolves inside the app container.
///
/// The folder keeps the app's first name, NameAlert, so that the configuration, the history and the downloaded
/// models written before the rename are still found.
///
/// These accessors only build URLs; the stores create the directories when they first write.
public enum AppPaths {
    /// `<Application Support>/NameAlert`
    public static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NameAlert", isDirectory: true)
    }

    /// `<Application Support>/NameAlert/config.json`
    public static var configFile: URL {
        applicationSupport.appendingPathComponent("config.json", isDirectory: false)
    }

    /// `<Application Support>/NameAlert/history.json`
    public static var historyFile: URL {
        applicationSupport.appendingPathComponent("history.json", isDirectory: false)
    }

    /// `<Application Support>/NameAlert/Models`
    public static var modelsDirectory: URL {
        applicationSupport.appendingPathComponent("Models", isDirectory: true)
    }
}
