// Compile an .mlpackage with MLModel.compileModel(at:), load it, run predictions.
// usage: swift swift_load.swift <model.mlpackage> [ALL|CPU_AND_NE|CPU_AND_GPU|CPU_ONLY] [runs]
import CoreML
import Foundation

func ms(_ t0: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
}

let args = CommandLine.arguments
let pkg = URL(fileURLWithPath: args[1])
let cuName = args.count > 2 ? args[2] : "ALL"
let runs = args.count > 3 ? Int(args[3])! : 20
// Optional 4th arg: raw little-endian float32 file with 1*3*640*640 values.
let inputFile = args.count > 4 ? args[4] : nil

let cfg = MLModelConfiguration()
switch cuName {
case "CPU_ONLY": cfg.computeUnits = .cpuOnly
case "CPU_AND_GPU": cfg.computeUnits = .cpuAndGPU
case "CPU_AND_NE": cfg.computeUnits = .cpuAndNeuralEngine
default: cfg.computeUnits = .all
}

do {
    var t = DispatchTime.now()
    let compiled = try await MLModel.compileModel(at: pkg)
    print(String(format: "compile_ms %.0f -> %@", ms(t), compiled.path))

    t = DispatchTime.now()
    let model = try MLModel(contentsOf: compiled, configuration: cfg)
    print(String(format: "load_ms %.0f (%@)", ms(t), cuName))

    let x = try MLMultiArray(shape: [1, 3, 640, 640], dataType: .float32)
    let n = x.count
    let fileData = try inputFile.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
    x.withUnsafeMutableBytes { raw, _ in
        let p = raw.bindMemory(to: Float.self)
        if let d = fileData {
            d.withUnsafeBytes { src in
                let f = src.bindMemory(to: Float.self)
                for i in 0..<n { p[i] = f[i] }
            }
        } else {
            for i in 0..<n { p[i] = Float(i % 255) / 255 }
        }
    }
    let input = try MLDictionaryFeatureProvider(dictionary: ["pixel_values": MLFeatureValue(multiArray: x)])

    t = DispatchTime.now()
    var out = try model.prediction(from: input)
    print(String(format: "first_predict_ms %.0f", ms(t)))
    var times: [Double] = []
    for _ in 0..<runs {
        t = DispatchTime.now()
        out = try model.prediction(from: input)
        times.append(ms(t))
    }
    times.sort()
    let logits = out.featureValue(for: "logits")!.multiArrayValue!
    let boxes = out.featureValue(for: "pred_boxes")!.multiArrayValue!
    print("logits shape \(logits.shape) boxes shape \(boxes.shape) box0 \(boxes[0]) \(boxes[1]) \(boxes[2]) \(boxes[3])")
    // Dump outputs for comparison with Python.
    if let f = inputFile {
        var dump = Data()
        for a in [logits, boxes] {
            for i in 0..<a.count { var v = a[i].floatValue; dump.append(Data(bytes: &v, count: 4)) }
        }
        try dump.write(to: URL(fileURLWithPath: f + ".swiftout"))
    }
    print(String(format: "predict_median_ms %.1f (n=%d)", times[times.count / 2], runs))
} catch {
    print("FAILED: \(error)")
    exit(1)
}
