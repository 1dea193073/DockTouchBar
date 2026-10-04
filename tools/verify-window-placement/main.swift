import AppKit
import ApplicationServices

enum AppSwitcher { static func requestAccessibilityAccess() { print("BLOCKED Accessibility missing") } }

let arguments=CommandLine.arguments
let label=arguments.count > 1 ? arguments[1] : "unknown"
let filter=arguments.count > 2 ? arguments[2] : "all"
let strictMotion=arguments.dropFirst(3).contains("--strict-motion")
guard ["all", "Finder", "Chrome", "Settings"].contains(filter) else { print("Usage: <label> all|Finder|Chrome|Settings [--strict-motion]"); exit(2) }
let app=NSApplication.shared
app.setActivationPolicy(.accessory)
guard AXIsProcessTrusted() else { print("BLOCKED Accessibility unavailable"); exit(2) }
let originalFront=NSWorkspace.shared.frontmostApplication
func settle(_ seconds:Double) { RunLoop.main.run(until:Date().addingTimeInterval(seconds)) }
func attribute(_ e:AXUIElement,_ key:String)->CFTypeRef? {
    var v:CFTypeRef?
    guard AXUIElementCopyAttributeValue(e,key as CFString,&v) == .success else { return nil }
    return v
}
func frame(_ w:AXUIElement)->CGRect? {
    var p=CGPoint.zero,s=CGSize.zero
    guard let v=attribute(w,kAXPositionAttribute),let z=attribute(w,kAXSizeAttribute),
          AXValueGetValue(v as! AXValue,.cgPoint,&p),AXValueGetValue(z as! AXValue,.cgSize,&s) else { return nil }
    return CGRect(origin:p,size:s)
}
func position(_ w:AXUIElement,_ p:CGPoint) { var p=p; if let v=AXValueCreate(.cgPoint,&p) { AXUIElementSetAttributeValue(w,kAXPositionAttribute as CFString,v) } }
func size(_ w:AXUIElement,_ s:CGSize) { var s=s; if let v=AXValueCreate(.cgSize,&s) { AXUIElementSetAttributeValue(w,kAXSizeAttribute as CFString,v) } }
func vals(_ r:CGRect)->[Double] { [r.minX,r.minY,r.width,r.height].map(Double.init) }
func same(_ a:CGRect,_ b:CGRect,_ tolerance:CGFloat=8)->Bool { abs(a.minX-b.minX)<=tolerance && abs(a.minY-b.minY)<=tolerance && abs(a.width-b.width)<=tolerance && abs(a.height-b.height)<=tolerance }
func centered(_ f:CGRect,_ area:CGRect)->Bool { abs(f.midX-area.midX)<=8 && abs(f.midY-area.midY)<=8 }
func cgFrame(_ pid:pid_t,_ ax:CGRect)->CGRect? {
    let windows=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
    return windows.filter { ($0[kCGWindowOwnerPID as String] as? Int)==Int(pid) && ($0[kCGWindowLayer as String] as? Int)==0 }.compactMap { info -> CGRect? in
        guard let b=info[kCGWindowBounds as String] as? [String:CGFloat],let x=b["X"],let y=b["Y"],let w=b["Width"],let h=b["Height"] else { return nil }; return CGRect(x:x,y:y,width:w,height:h)
    }.min { a,b in abs(a.minX-ax.minX)+abs(a.minY-ax.minY)+abs(a.width-ax.width) < abs(b.minX-ax.minX)+abs(b.minY-ax.minY)+abs(b.width-ax.width) }
}
var failures=0
var records=[[String:Any]]()
let primaryHeight=NSScreen.screens.first!.frame.height
func areaFor(_ r:CGRect)->CGRect {
    let screen=NSScreen.screens.first { s in CGRect(x:s.frame.minX,y:primaryHeight-s.frame.maxY,width:s.frame.width,height:s.frame.height).contains(CGPoint(x:r.midX,y:r.midY)) } ?? NSScreen.main!
    let v=screen.visibleFrame
    return CGRect(x:v.minX,y:primaryHeight-v.maxY,width:v.width,height:v.height)
}
let targets=[("Finder","com.apple.finder",false),("Chrome","com.google.Chrome",false),("Settings","com.apple.systempreferences",true)]
for (name,id,constrained) in targets where filter == "all" || filter == name {
    guard let running=NSRunningApplication.runningApplications(withBundleIdentifier:id).first else { print("BLOCKED \(name) not running"); failures+=1;continue }
    let element=AXUIElementCreateApplication(running.processIdentifier)
    AXUIElementSetMessagingTimeout(element,0.3)
    guard let windows=attribute(element,kAXWindowsAttribute) as? [AXUIElement],let w=windows.first(where:{ (attribute($0,kAXRoleAttribute) as? String)==kAXWindowRole }),let original=frame(w) else { print("BLOCKED \(name) no window");failures+=1;continue }
    AXUIElementSetMessagingTimeout(w,0.3)
    running.activate()
    AXUIElementPerformAction(w,kAXRaiseAction as CFString)
    settle(0.4)
    let area=areaFor(original)
    let target=CGRect(x:(area.midX-area.width*0.7/2).rounded(),y:(area.midY-area.height*0.9/2).rounded(),width:(area.width*0.7).rounded(),height:(area.height*0.9).rounded())
    size(w,CGSize(width:700,height:420));settle(0.15)
    position(w,CGPoint(x:area.minX+400,y:area.minY+350));settle(0.25)
    for index in 0..<7 {
        if index == 6 {
            // 模拟用户自由调整后，下一次必须回到配置居中，不能继续信任上次动作记忆。
            size(w,CGSize(width:700,height:420));settle(0.3)
            position(w,CGPoint(x:area.minX+400,y:area.minY+350));settle(0.35)
        }
        running.activate()
        AXUIElementPerformAction(w,kAXRaiseAction as CFString)
        settle(0.35)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == running.processIdentifier else { print("BLOCKED foreground changed for \(name)"); failures+=1; break }
        let before=frame(w)!
        var done=false
        var next="none"
        let started=Date()
        var finished:Date?
        var samples=[[Double]]()
        WindowPlacer.toggleFrontmost(heightPercent:90,widthPercent:70) { action in done=true;finished=Date();next=action == .center ? "center" : "maximize" }
        while Date().timeIntervalSince(started)<5 {
            if let f=frame(w) { samples.append([Date().timeIntervalSince(started)]+vals(f)) }
            if done,let finished,Date().timeIntervalSince(finished)>1 { break }
            settle(0.012)
        }
        let actual=frame(w)!
        let cg=cgFrame(running.processIdentifier,actual)
        let centerAction=index%2==0
        let geometryOK=constrained ? centered(actual,area) && abs(actual.height-(centerAction ? target.height : area.height))<=8 : same(actual,centerAction ? target : area)
        let cgOK=cg.map { same($0,actual) } ?? false
        let xs=samples.map{$0[1]}
        let xSpan=(xs.max() ?? 0)-(xs.min() ?? 0)
        let stableXOK = !constrained || !centered(before,area) || xSpan<=8
        let noOvershoot = !constrained || xs.allSatisfy { $0 >= Double(min(before.minX,actual.minX))-8 && $0 <= Double(max(before.minX,actual.minX))+8 }
        let motionOK = !strictMotion || (stableXOK && noOvershoot)
        let ok=done && geometryOK && cgOK && motionOK && next==(centerAction ? "maximize" : "center")
        if !ok { failures+=1 }
        let record:[String:Any]=["implementation":label,"app":name,"step":index+1,"action":centerAction ? "center" : "maximize","before":vals(before),"actual":vals(actual),"cg":cg.map(vals) ?? [],"area":vals(area),"next":next,"geometryOK":geometryOK,"cgOK":cgOK,"xSpan":xSpan,"stableXOK":stableXOK,"noOvershoot":noOvershoot,"motionCriteriaEnforced":strictMotion,"passed":ok,"samples":samples]
        records.append(record)
        print("\(ok ? "PASS" : "FAIL") \(label) \(name) step=\(index+1) \(centerAction ? "center" : "maximize") AX=\(vals(actual)) CG=\(cg.map(vals) ?? []) next=\(next) xSpan=\(xSpan) noOvershoot=\(noOvershoot)")
        fflush(stdout)
    }
    // 恢复原布局：先缩小腾出空间，再还原原点及原尺寸。
    size(w,CGSize(width:min(original.width,700),height:min(original.height,420)));settle(0.1)
    position(w,original.origin);settle(0.1);size(w,original.size);settle(0.3);position(w,original.origin);settle(0.1)
    let restored=frame(w).map{same($0,original)} ?? false
    print("RESTORE \(name) \(restored ? "PASS" : "FAIL")")
    if !restored { failures+=1 }
}
originalFront?.activate()
let output=URL(fileURLWithPath:"build/diagnostics/window-regression/\(label)-\(filter).json")
try! JSONSerialization.data(withJSONObject:["implementation":label,"motionCriteriaEnforced":strictMotion,"failures":failures,"records":records],options:[.prettyPrinted,.sortedKeys]).write(to:output)
print("RESULT failures=\(failures)")
exit(failures==0 ? 0:1)
