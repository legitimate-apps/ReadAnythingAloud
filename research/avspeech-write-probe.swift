import AVFoundation
var frames = 0
final class D: NSObject, AVSpeechSynthesizerDelegate {
  var log: [(NSRange, Int)] = []
  func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString r: NSRange, utterance: AVSpeechUtterance) { log.append((r, frames)) }
}
let text = "Hello world. This is a test of word markers. Reading articles aloud is fun."
let s = AVSpeechSynthesizer(); let d = D(); s.delegate = d
let u = AVSpeechUtterance(string: text)
let done = DispatchSemaphore(value: 0); var bufs = 0
s.write(u, toBufferCallback: { b in
  guard let pcm = b as? AVAudioPCMBuffer else { return }
  if pcm.frameLength == 0 { done.signal(); return }
  frames += Int(pcm.frameLength); bufs += 1
}, toMarkerCallback: { m in print("markers", m.count) })
let deadline = Date().addingTimeInterval(20)
while done.wait(timeout: .now() + 0.02) == .timedOut && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
RunLoop.current.run(until: Date().addingTimeInterval(0.5))
let ns = text as NSString
print("buffers", bufs, "total frames", frames, "sec", Double(frames)/22050)
for (r, f) in d.log { print(String(format: "%-10@ frames_at_cb=%6d (%.2fs)", ns.substring(with: r), f, Double(f)/22050)) }
