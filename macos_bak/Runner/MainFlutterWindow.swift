import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()

    // 关键：启动先隐藏窗口，不会弹出默认小尺寸
    self.orderOut(nil)

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
        // 进入系统标准全屏
        self.toggleFullScreen(nil)
        // 自动隐藏顶部菜单栏、底部Dock（收银机纯全屏）
        NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
        // 全屏完成后再展示窗口，看不到小窗过渡
        self.makeKeyAndOrderFront(nil)
    }
  }
}