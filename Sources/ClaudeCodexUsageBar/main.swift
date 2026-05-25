import Cocoa

// メニューバー常駐アプリのエントリーポイント
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// LSUIElement=true により Dock アイコンは出さない（Info.plist 側で指定）
app.setActivationPolicy(.accessory)
app.run()
