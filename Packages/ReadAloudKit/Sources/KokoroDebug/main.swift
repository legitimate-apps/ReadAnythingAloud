import FluidAudio
import Foundation
let m = KokoroAneManager(variant: .english)
try await m.initialize()
for text in CommandLine.arguments.dropFirst() {
    let r = try await m.synthesizeDetailed(text: text)
    print("TEXT:", text)
    print("NORM:", r.normalizedText ?? "nil")
    print("PHON:", r.phonemes)
    print("IDS:", r.inputIds.map(String.init).joined(separator: ","))
    print("DUR:", r.predictedDurations.map(String.init).joined(separator: ","))
    print("groups(phon split):", r.phonemes.split(separator: " ").count, "norm words:", (r.normalizedText ?? "").split(separator: " ").count)
}
