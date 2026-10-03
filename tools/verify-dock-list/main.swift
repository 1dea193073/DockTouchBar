import AppKit

// 使用生产控制器和真正的 NSScrubber；只替换数据，不退出或启动用户的 App。
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() { print("PASS \(message)") }
    else { print("FAIL \(message)"); failures += 1 }
}
func settle() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
}
func tile(_ number: Int, temporary: Bool = false) -> DockTile {
    DockTile(kind: .app, url: URL(fileURLWithPath: "/tmp/DockList-\(number).app"),
             bundleID: "test.\(number)", isRunning: true, isTemporary: temporary)
}

for includePinned in [true, false] {
    let model = DockModel.tiles(includePinned: includePinned)
    // 固定模式下垃圾桶始终在；只显示运行中的 App 时，只有废纸篓窗口开着才在。
    let trashes = model.filter { $0.kind == .trash }
    check(includePinned ? (trashes.count == 1 && model.last?.kind == .trash)
                        : (trashes.isEmpty ? !model.contains { $0.kind == .divider } : model.last?.kind == .trash),
          "Trash at the end (pinned) / only while its window is open (running-only)")
    if !includePinned { check(model.allSatisfy { $0.isRunning || $0.kind == .divider }, "Running-only: no dimmed icons") }
    // 固定模式下访达始终在；只显示运行中的 App 时，访达只在有窗口时出现，并排在最左。
    let finders = model.filter { $0.bundleID == "com.apple.finder" }
    check(includePinned ? finders.count == 1 : (finders.count <= 1 && (finders.isEmpty || model.first?.bundleID == "com.apple.finder")),
          "Finder appears once (pinned) / only when it has windows, at the far left (running-only)")
    let apps = model.filter { $0.kind == .app }
    check(Set(apps.compactMap(\.url)).count == apps.count, "No duplicate app icons")
    let launches = apps.prefix { $0.bundleID != "com.apple.finder" }.compactMap { tile -> Date? in
        guard let url = tile.url else { return nil }
        return DockModel.runningApp(bundleID: tile.bundleID, url: url)?.launchDate
    }
    check(zip(launches, launches.dropFirst()).allSatisfy { $0 >= $1 }, "Newest launched apps come first")
}
check(DockTile.trash.url.flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }?.lastPathComponent == "Finder.app",
      "Trash URL is handled by Finder")
check(DockTile.trash.url.flatMap { IconCache.image(for: $0, pointSize: 28) } != nil, "Trash icon renders")

var data = (0..<45).map { tile($0) } + [.divider, .trash]
DockModel.previewTiles = data
let controller = DockBarController()
controller.reload()
let item = controller.touchBar(NSTouchBar(), makeItemForIdentifier: .init("com.maohuhu.docktouchbar.dock")) as! NSCustomTouchBarItem
let container = item.view
let scrubber = container.subviews.compactMap { $0 as? NSScrubber }.first!
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 30),
                      styleMask: .borderless, backing: .buffered, defer: false)
let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 30))
window.contentView = root
root.addSubview(container)
NSLayoutConstraint.activate([
    container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
    container.topAnchor.constraint(equalTo: root.topAnchor)
])
root.layoutSubtreeIfNeeded()
settle()

func update(_ next: [DockTile]) {
    data = next
    DockModel.previewTiles = data
    controller.reload()
    root.layoutSubtreeIfNeeded()
    settle()
    check(scrubber.numberOfItems == data.count, "Item count matches after update (\(data.count))")
}
func visible(_ index: Int) -> Bool {
    guard let frame = scrubber.scrubberLayout.layoutAttributesForItem(at: index)?.frame else { return false }
    return frame.intersects(scrubber.scrubberLayout.visibleRect)
}

scrubber.scrollItem(at: 44, to: .trailing)
settle()
let before = scrubber.scrubberLayout.visibleRect.minX
check(before > 500 && visible(44), "Long list scrolled to a far-right app")
update(Array(data.dropLast(3)) + [.divider, .trash])
let after = scrubber.scrubberLayout.visibleRect.minX
check(after > 500 && abs(after - before) < 60, "Closing far-right app keeps the current area, without returning to start")

// 关掉可视区域左边的图标，保留当前可见图标，不能退回初始位置。
let anchorIndex = data.indices.first { visible($0) }!
let anchor = data[anchorIndex]
update(Array(data.dropFirst()))
let movedAnchor = data.firstIndex { $0.isSameSlot(as: anchor) }!
check(visible(movedAnchor) && scrubber.scrubberLayout.visibleRect.minX > 500, "Removing an app before viewport preserves visible anchor")

let oldOffset = scrubber.scrubberLayout.visibleRect.minX
var states = data
states[5].isFrontmost = true
update(states)
check(abs(scrubber.scrubberLayout.visibleRect.minX - oldOffset) < 1, "Activation-only refresh preserves exact scroll position")

update([tile(100, temporary: true), .temporaryDivider] + data)
check(scrubber.scrubberLayout.visibleRect.minX < 1 && visible(0), "New temporary app is immediately visible on the left")
scrubber.scrollItem(at: 30, to: .leading)
settle()
var adjacent = data
adjacent.remove(at: 0)
adjacent.remove(at: 0)
update(adjacent)
check(scrubber.scrubberLayout.visibleRect.minX > 500, "Quitting temporary app while scrolled does not reset viewport")

update(Array(data.reversed()))
check(scrubber.numberOfItems == data.count, "Reordering uses consistent sequential indexes")
update([tile(1), .divider, .trash])
check(scrubber.scrubberLayout.visibleRect.minX < 1, "Shortened list clamps to available content")
update([])
check(scrubber.numberOfItems == 0, "Empty preview list is handled")
update([tile(2), .divider, .trash])
check(visible(0), "Repopulated list is visible")
if CommandLine.arguments.contains("--open-trash") {
    controller.scrubber(scrubber, didSelectItemAt: data.count - 1)
    settle()
    print("Requested Trash using the production tap handler")
}

print("RESULT failures=\(failures)")
exit(failures == 0 ? 0 : 1)
