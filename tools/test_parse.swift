// Reproduces the console window's exact data path against the live daemon:
// GlueClient socket → JuceStreamReader tree → findNode/intProp/doubleProp →
// the ConsoleWindowController.updateTree parse logic. Prints what the app
// actually sees for hwin/hwout.
import AppKit
import Foundation

func run() {
let glue = GlueClient()
let sem = DispatchSemaphore(value: 0)

glue.onTree = { tree in
    print("=== tree received ===")
    for i in 0..<4 {
        var name: String? = nil, refLevel: Int? = nil, sl: Int? = nil, pol: Int? = nil
        var phantom: Int? = nil, micGain: Double? = nil, instGain: Double? = nil
        if let node = GlueClient.findNode(in: tree, type: "hwin\(i)") {
            let props = node["props"] as? [String: Any]
            name = props?["name"] as? String
            refLevel = GlueClient.intProp(node, "analogRefLevel")
            sl = GlueClient.intProp(node, "softLimit")
            pol = GlueClient.intProp(node, "polarityInvert")
            if let mic = GlueClient.findNode(in: node, type: "micSettings") {
                phantom = GlueClient.intProp(mic, "phantom")
                if let pre = GlueClient.findNode(in: mic, type: "PreModelQuartet") {
                    micGain = GlueClient.doubleProp(pre, "gain")
                } else { print("   !! PreModelQuartet (mic) NOT FOUND for hwin\(i)") }
            } else { print("   !! micSettings NOT FOUND for hwin\(i)") }
            if let inst = GlueClient.findNode(in: node, type: "instSettings"),
               let pre = GlueClient.findNode(in: inst, type: "PreModelQuartet") {
                instGain = GlueClient.doubleProp(pre, "gain")
            }
            let kids = (node["children"] as? [[String: Any]])?.map { $0["type"] as? String ?? "?" } ?? []
            print("hwin\(i) name=\(name ?? "?") ref=\(refLevel.map(String.init) ?? "nil") soft=\(sl.map(String.init) ?? "nil") pol=\(pol.map(String.init) ?? "nil") phantom=\(phantom.map(String.init) ?? "nil") micGain=\(micGain.map { String(format: "%.2f", $0) } ?? "nil") instGain=\(instGain.map { String(format: "%.2f", $0) } ?? "nil") children=\(kids)")
        } else {
            print("!! hwin\(i) NOT FOUND in tree")
        }
    }
    for o in 0..<2 {
        if let node = GlueClient.findNode(in: tree, type: "hwout\(o)") {
            print("hwout\(o) gain=\(GlueClient.doubleProp(node, "gain").map { String(format: "%.1f", $0) } ?? "nil") mute=\(GlueClient.intProp(node, "mute").map(String.init) ?? "nil") dim=\(GlueClient.intProp(node, "dim").map(String.init) ?? "nil") sum=\(GlueClient.intProp(node, "sum").map(String.init) ?? "nil")")
        }
    }
    sem.signal()
}

glue.connect()
_ = sem.wait(timeout: .now() + 6)
print("done")
}