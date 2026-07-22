import AppKit
import Darwin
import SwiftUI

extension Notification.Name {
    static let openPhotoFolder = Notification.Name("MotionAlbum.openPhotoFolder")
}

private func uncaughtExceptionHandler(_ exception: NSException) {
    AppLogger.error(
        "未捕获异常：\(exception.name.rawValue) - \(exception.reason ?? "无详细信息")"
    )
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSSetUncaughtExceptionHandler(uncaughtExceptionHandler)
        AppLogger.info("应用启动")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct MotionAlbumApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        if CommandLine.arguments.contains("--self-test") {
            let result = SelfTest.run()
            fflush(stdout)
            exit(result)
        }
    }

    var body: some Scene {
        WindowGroup(AppIdentity.displayName) {
            ContentView()
        }
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开照片文件夹…") {
                    NotificationCenter.default.post(name: .openPhotoFolder, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
