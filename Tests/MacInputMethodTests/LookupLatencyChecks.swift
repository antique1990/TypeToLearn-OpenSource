import AppKit
import KeyboardCore

private struct LatencyFailure: Error { let message: String }

@main struct LookupLatencyChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let lexicon = try Lexicon(url: resources.appendingPathComponent("lexicon.sqlite"))
        // Warm Rime independently: this assertion measures waiting on spelling,
        // not native compilation or the operating system's file cache.
        _ = try await lexicon.candidates(for: "nihao", layout: .pinyin, script: .simplified,
            limit: 48, pinyinPolicy: .configured([]))
        var initial: [Candidate] = []
        var initialLatency: Duration?
        var sawInitialBeforeSpellingReturned = false
        let start = ContinuousClock.now
        let result = try await MacCandidateLookup.candidates(for: "nihao", layout: .pinyin,
            script: .simplified, englishMode: false, lexicon: lexicon, pinyinPolicy: .configured([]),
            completionProvider: { _ in
                try? await Task.sleep(for: .milliseconds(300))
                sawInitialBeforeSpellingReturned = initial.first?.text == "你好"
                return []
            }, onInitial: { values in
                initial = values
                initialLatency = start.duration(to: .now)
            })
        guard sawInitialBeforeSpellingReturned else {
            throw LatencyFailure(message: "Chinese candidates waited for the slow spelling service")
        }
        guard let initialLatency, initialLatency < .milliseconds(150), initial == result else {
            throw LatencyFailure(message: "Initial Chinese candidates were delayed or changed")
        }
        print("PASS: Chinese candidates published in \(initialLatency), before 300ms spelling reply")

        var originalShown = false
        let english = try await MacCandidateLookup.candidates(for: "appli", layout: .pinyin,
            script: .simplified, englishMode: true, lexicon: lexicon,
            completionProvider: { _ in
                try? await Task.sleep(for: .milliseconds(50))
                return ["application"]
            }, onInitial: { values in originalShown = values.first?.text == "appli" })
        guard originalShown, english.map(\.text).contains("application") else {
            throw LatencyFailure(message: "English spelling/completions did not publish in two stages")
        }
        print("PASS: English original spelling appears before asynchronous suggestions")

        var cancelledInitial = false
        let cancelled = Task { @MainActor in
            try await MacCandidateLookup.candidates(for: "nihao", layout: .pinyin,
                script: .simplified, englishMode: false, lexicon: lexicon,
                completionProvider: { _ in
                    // Simulate an external service that returns despite cancellation.
                    await withCheckedContinuation { done in
                        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { done.resume(returning: ["nihao"]) }
                    }
                }, onInitial: { _ in cancelledInitial = true })
        }
        while !cancelledInitial { try await Task.sleep(for: .milliseconds(1)) }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            throw LatencyFailure(message: "Cancelled spelling response was returned as current candidates")
        } catch is CancellationError {}
        print("PASS: obsolete spelling replies are cancelled")
        var maxHeartbeatPause = Duration.zero
        var heartbeatCount = 0
        let heartbeat = Task { @MainActor in
            var previous = ContinuousClock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
                let now = ContinuousClock.now
                maxHeartbeatPause = max(maxHeartbeatPause, previous.duration(to: now))
                previous = now; heartbeatCount += 1
            }
        }
        try await Task.sleep(for: .milliseconds(10))
        let realStart = ContinuousClock.now
        var realInitialLatency: Duration?
        let real = try await MacCandidateLookup.candidates(for: "nihao", layout: .pinyin,
            script: .simplified, englishMode: false, lexicon: lexicon, pinyinPolicy: .configured([]),
            onInitial: { _ in realInitialLatency = realStart.duration(to: .now) })
        heartbeat.cancel(); await heartbeat.value
        guard real.first?.text == "你好", realInitialLatency != nil else {
            throw LatencyFailure(message: "Real AppKit spelling changed ordinary Chinese candidates")
        }
        print("Native AppKit: initial \(realInitialLatency!), complete \(realStart.duration(to: .now)), main-loop ticks \(heartbeatCount), longest pause \(maxHeartbeatPause)")
        await lexicon.close()
    }
}
