# Findly

把 Finder 視窗釘在螢幕任一邊。從選單列、全域快捷鍵、或點 Dock 的 Finder 圖示就能召喚出來；點到其他 app 就自動滑回邊外。

<p align="center">
  <img src="Resources/icon-1024.png" width="160" alt="Findly icon">
</p>

## 它在做什麼

Findly 是一個 macOS menu bar 小工具。它在背景管理「一個」Finder 視窗，可以從螢幕四側任一邊滑進/滑出，整個畫面只露出 Finder 視窗本身（不再覆蓋一層自家 UI）。

- ⌃⌥ ↑ / ↓ / ← / → 召喚到上/下/左/右
- 滑鼠在哪個螢幕，就召喚到那個螢幕
- 點到其他 app → Finder 自動滑出螢幕外
- 再按一次快捷鍵 → 滑回原本的資料夾、原本的卷軸位置
- 拖過邊界調整寬高 → 下次召喚記得

## 為什麼

Unclutter 之類的工具讓你從螢幕上緣下滑出一個抽屜，可以隨手暫存檔案、筆記、剪貼簿。但只有一個邊、抽屜內也只是自家簡化 UI——要找檔案還是得開 Finder。

Findly 換個方向：**不重做檔案瀏覽 UI**，直接把真正的 Finder 視窗變成那個抽屜。四個邊都能滑入滑出、Finder 的 sidebar / column view / 標籤頁 / 雙擊行為通通保留——因為它本來就是 Finder。

## 安裝

```bash
git clone https://github.com/rocavence/Findly-app.git
cd Findly-app
./Scripts/build-app.sh
open build/Findly.app
```

第一次跑會跳兩個系統授權對話框，都允許：
1. **Apple Events** → 控制 Finder 視窗位置
2. **輔助使用（Accessibility）** → 流暢的 60/120Hz 動畫

需要安裝完整 Xcode 才能簽章發布；本機自己用只需 Command Line Tools。

## 使用

| 動作 | 觸發方式 |
|---|---|
| 召喚到某一邊 | menu bar icon → 選 Snap / ⌃⌥+方向鍵 |
| 收起 | 點到其他 app（自動）/ 同樣的快捷鍵再按一次 |
| 重新召喚 | 任何召喚動作；會回到上次的資料夾 |
| 點 Dock 的 Finder | 也會把 Findly 那個視窗滑回最近的邊 |
| 改寬高 | 拖視窗邊界，會記住，下次召喚用同樣寬度 |

## 開發思路

這份是我用 [Claude Code](https://claude.com/claude-code) 在一段對話裡邊聊邊做出來的。記錄一下重要的彎路：

### 抽屜內容要自己刻嗎

一開始走 SwiftUI 路線想做一個 `NavigationSplitView` + sidebar 的檔案瀏覽器塞進 `NSPanel`。但 macOS sandbox 下沒辦法把 Finder 的 view 嵌進別 app 的視窗，只能自己刻——刻完永遠不會跟真 Finder 一模一樣。

後來退一步用 `NSBrowser`（Finder column view 的底層元件），看起來 80% 像，但搜尋、tag、context menu 還是缺。

最終決定：**不要刻**。直接用 AppleScript 開一個 Finder 視窗，再用 Accessibility API 控制它的位置和大小。完全不畫自己的 UI。

### 動畫怎麼跑得順

AppleScript 設 bounds 每次要 ~20-50ms 的 IPC，當動畫 frame 用會卡。改用 `AXUIElementSetAttributeValue` 設 position/size——in-process call，幾乎零延遲。

frame-count 迴圈（固定 20 幀）改成 time-based（用 `Date()` 算 progress），慢 tick 會自動掉幀但動畫總時長固定在 220ms。tick 間隔降到 8ms 配合 ProMotion 120Hz。

AppleScript 仍作為 fallback——AX 失效（Finder 重啟、視窗關掉）時自動降級。

### 怎麼知道是「我們的」視窗

使用者可能同時開了很多 Finder 視窗。Findly 不能去動別人的。解法：

1. 第一次召喚時 `make new Finder window`，AppleScript 回傳那個 window 的 `id`
2. 之後所有操作都 `first Finder window whose id is N` 鎖定那一個
3. ID 持久化在 UserDefaults，跨 app 重啟也記得
4. 如果使用者手動關掉那個 window，下次召喚會無痛重建

### 自動 park 怎麼不打架

監聽 `NSWorkspace.didActivateApplicationNotification`：

- 其他 app activate → park Finder（滑出邊外）
- Finder activate → 區分是「我們」呼叫的（時間戳記 < 1 秒）還是「使用者點 Dock 的」，後者觸發 slide in

### 收起時怎麼不留痕跡

park 不能用「Cmd+H 隱藏 Finder」——會把使用者其他 Finder 視窗也一起隱藏。改成把 window bounds 設到螢幕外（buffer 50px 涵蓋原生陰影），視窗物理上還在、狀態完全保留，只是位置看不到。下次召喚就用原本的 window 滑回來——路徑、卷軸、選取狀態全保留。

### Glow overlay 的取捨

中間做過一版「Finder 視窗外圍一圈柔光」效果，當 focused state 提示。寫了 `CAShapeLayer` + mask + CGContext blur 三種實作，每一種要嘛 mask 沒生效、要嘛太吃 CPU 影響動畫。

最後拿掉。Finder 自己的 window shadow + 滑入滑出動畫本身就夠提示了，多此一舉只會吃資源。

## 技術棧

- **Swift 6** / **AppKit**（純 system framework，沒有第三方依賴）
- **NSAppleScript** 控制 Finder（建立 / 找窗 / 關閉）
- **Accessibility API**（`AXUIElement`）平滑位置動畫 + 監聽使用者 resize
- **Carbon `RegisterEventHotKey`** 全域快捷鍵（不需新增權限）
- **Swift Package Manager** + shell script 打 `.app` bundle + ad-hoc codesign
- **`CGContext` + `sips` + `iconutil`** 程式化生成 icon

## 專案結構

```
Findly-app/
├── Package.swift
├── Sources/Findly/
│   ├── main.swift              # NSApplication entry
│   ├── AppDelegate.swift       # menu bar + hotkey routing
│   ├── FinderController.swift  # 核心：建窗 / 動畫 / 觀察者
│   ├── HotkeyManager.swift     # Carbon 全域快捷鍵
│   ├── ScreenEdge.swift        # 邊緣 frame 計算
│   └── Defaults.swift          # UserDefaults wrapper
├── Resources/
│   ├── Info.plist              # CFBundleID, usage descriptions
│   ├── AppIcon.icns
│   └── icon-1024.png
├── Scripts/
│   ├── build-app.sh            # SPM → .app bundle + codesign
│   ├── make-icon.swift         # 程式化渲染 1024 master
│   └── make-icon.sh            # iconset + .icns
└── Tests/FindlyTests/
```

## 已知限制

- 只在 macOS 14+ 測過，主力測試環境 macOS 26（Tahoe）
- Ad-hoc codesign 只能自己用；給別人裝會被 Gatekeeper 擋（需要 Developer ID + notarization）
- 視窗圓角值（macOS 26 = 22）只是接近值，沒有公開 API 拿正式值
- Full-screen Space 切換時，Findly 的 Finder 視窗在原本的 Space 上等使用者回去

## 授權

MIT
