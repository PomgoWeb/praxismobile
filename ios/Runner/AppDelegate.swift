import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let nativeLogFileName = "rsapp.log"
  private let nativeTimestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    appendNativeLog("ios.didFinishLaunching.enter")
    appendNativeLog("ios.didFinishLaunching.before_generated_plugins")
    GeneratedPluginRegistrant.register(with: self)
    appendNativeLog("ios.didFinishLaunching.after_generated_plugins")
    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    appendNativeLog("ios.didFinishLaunching.after_super result=\(result)")
    return result
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    appendNativeLog("ios.applicationDidBecomeActive")
    super.applicationDidBecomeActive(application)
  }

  private func appendNativeLog(_ message: String) {
    let timestamp = nativeTimestampFormatter.string(from: Date())
    let line = "\(timestamp) [IOS] \(message)\n"

    guard let documentsUrl = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
      NSLog("%@", line)
      return
    }

    let logFileUrl = documentsUrl.appendingPathComponent(nativeLogFileName)
    let data = Data(line.utf8)

    do {
      if !FileManager.default.fileExists(atPath: logFileUrl.path) {
        try data.write(to: logFileUrl, options: .atomic)
        return
      }

      let handle = try FileHandle(forWritingTo: logFileUrl)
      defer {
        handle.closeFile()
      }
      handle.seekToEndOfFile()
      handle.write(data)
    } catch {
      NSLog("%@", line)
      NSLog("ios.nativeLogWriteFailed %@", error.localizedDescription)
    }
  }
}
