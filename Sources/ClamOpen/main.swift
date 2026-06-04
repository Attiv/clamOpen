import AppKit

// 菜单栏 App 入口。delegate 用顶层常量持有，防止被释放。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
