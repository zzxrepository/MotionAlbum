import AppKit
import Darwin
import SwiftUI

extension Notification.Name {
    static let openPhotoFolder = Notification.Name("MotionAlbum.openPhotoFolder")
    static let createPhotoFolder = Notification.Name("MotionAlbum.createPhotoFolder")
    static let refreshPhotoFolder = Notification.Name("MotionAlbum.refreshPhotoFolder")
    static let collapsePhotoFolders = Notification.Name("MotionAlbum.collapsePhotoFolders")
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
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开照片文件夹…") {
                    NotificationCenter.default.post(name: .openPhotoFolder, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("新建文件夹…") {
                    NotificationCenter.default.post(name: .createPhotoFolder, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }

            CommandMenu("资源管理器") {
                Button("刷新") {
                    NotificationCenter.default.post(name: .refreshPhotoFolder, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("全部收起") {
                    NotificationCenter.default.post(name: .collapsePhotoFolders, object: nil)
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
            }
        }
    }
}
