import Foundation

extension SessionController {
    func clearStreamingAccumulator() {
        streamingAccumulator = nil
        streamingAccumulatorNeedsSnapshot = false
    }

    func resetStreamingState() {
        // Show what the reveal had not reached yet, including any paragraph
        // held back, so stopping never drops received text.
        materializeStreamingAccumulatorSnapshot(complete: true)
        if var target = streamingTargetMessage,
           let index = messages.firstIndex(where: { $0.id == target.id }) {
            target.isStreaming = false
            target.tools = mergeTools(existing: messages[index].tools, incoming: target.tools)
            messages[index] = target
            streamingFrameToken += 1
        }
        streamingRevealGeneration += 1
        streamingRevealScheduled = false
        if let id = streamingMessageID,
           let index = messages.firstIndex(where: { $0.id == id }),
           messages[index].isStreaming {
            messages[index].isStreaming = false
            streamingFrameToken += 1
        }
        streamingMessageID = nil
        streamingTargetMessage = nil
        clearStreamingAccumulator()
    }

    func ensureStreamingMessageExists(id: String) {
        if !messages.contains(where: { $0.id == id }) {
            messages.append(ChatMessage(id: id, role: .assistant, isStreaming: true))
            streamingFrameToken += 1
        }
    }

    func setStreamingTarget(_ target: ChatMessage, authoritativeTools: Bool = false) {
        updateStreamingTarget(target, authoritativeTools: authoritativeTools)
        scheduleStreamingReveal()
    }

    private func updateStreamingTarget(_ target: ChatMessage, authoritativeTools: Bool = false) {
        var merged = target
        if let current = messages.first(where: { $0.id == target.id }) {
            merged.tools = authoritativeTools
                ? reconcileToolExecution(existing: current.tools, authoritative: target.tools)
                : mergeTools(existing: current.tools, incoming: target.tools)
        }
        if let previous = streamingTargetMessage, previous.id == target.id {
            merged.tools = authoritativeTools
                ? reconcileToolExecution(existing: previous.tools, authoritative: merged.tools)
                : mergeTools(existing: previous.tools, incoming: merged.tools)
        }
        streamingTargetMessage = merged
    }

    /// `complete` takes everything streamed so far, including any unfinished
    /// paragraph that paragraph mode was holding back.
    private func materializeStreamingAccumulatorSnapshot(complete: Bool = false) {
        guard streamingAccumulatorNeedsSnapshot || complete,
              let accumulator = streamingAccumulator,
              let id = streamingMessageID else { return }
        streamingAccumulatorNeedsSnapshot = false
        let finishedParagraphsOnly = !complete && ResponseStreamingPreference.current == .paragraphs
        updateStreamingTarget(accumulator.message(id: id, finishedParagraphsOnly: finishedParagraphsOnly))
    }

    func reconcileToolExecution(existing: [ToolDisplay], authoritative: [ToolDisplay]) -> [ToolDisplay] {
        authoritative.map { tool in
            guard let old = existing.first(where: { $0.id == tool.id }) else { return tool }
            var reconciled = tool
            if !old.result.isEmpty { reconciled.result = old.result }
            reconciled.details = old.details ?? tool.details
            if reconciled.images.isEmpty { reconciled.images = old.images }
            if old.status != .pending { reconciled.status = old.status }
            reconciled.isError = old.isError || tool.isError
            return reconciled
        }
    }

    func scheduleStreamingReveal() {
        guard !streamingRevealScheduled else { return }
        streamingRevealScheduled = true
        streamingRevealGeneration += 1
        let generation = streamingRevealGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + streamingRevealInterval) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.streamingRevealGeneration == generation else { return }
                self.streamingRevealScheduled = false
                self.runStreamingRevealFrame()
            }
        }
    }

    private func runStreamingRevealFrame() {
        materializeStreamingAccumulatorSnapshot()
        guard let target = streamingTargetMessage else { return }
        if paragraphRevealIsThrottled(toward: target) {
            // The snapshot is cumulative, so a later frame shows everything finished meanwhile.
            scheduleStreamingReveal()
            return
        }
        let complete = applyStreamingRevealFrame(toward: target)
        if complete {
            if !target.isStreaming {
                streamingTargetMessage = nil
                streamingMessageID = nil
            }
        } else {
            scheduleStreamingReveal()
        }
    }

    private func paragraphRevealIsThrottled(toward target: ChatMessage) -> Bool {
        guard ResponseStreamingPreference.current == .paragraphs,
              Date().timeIntervalSince(lastTextRevealAt) < paragraphRevealInterval,
              let current = messages.first(where: { $0.id == target.id }) else { return false }
        return current.text != target.text || current.thinking != target.thinking
    }

    func finishStreamingReveal(immediate: Bool) {
        streamingRevealGeneration += 1
        streamingRevealScheduled = false
        materializeStreamingAccumulatorSnapshot(complete: true)
        guard let target = streamingTargetMessage else {
            if let id = streamingMessageID, let index = messages.firstIndex(where: { $0.id == id }), messages[index].isStreaming {
                messages[index].isStreaming = false
                streamingFrameToken += 1
            }
            streamingMessageID = nil
            return
        }
        var final = target
        final.isStreaming = false
        if immediate {
            applyStreamingMessage(final)
            streamingTargetMessage = nil
            streamingMessageID = nil
        } else {
            streamingTargetMessage = final
            scheduleStreamingReveal()
        }
    }

    @discardableResult
    private func applyStreamingRevealFrame(toward target: ChatMessage) -> Bool {
        ensureStreamingMessageExists(id: target.id)
        guard let index = messages.firstIndex(where: { $0.id == target.id }) else { return true }
        let current = messages[index]
        let textPlan = streamingRevealPlan(from: current.text, to: target.text)
        let thinkingPlan = streamingRevealPlan(from: current.thinking, to: target.thinking)
        // Paragraph mode shows each finished block whole instead of typing it out.
        var budget = ResponseStreamingPreference.current == .paragraphs
            ? textPlan.remaining + thinkingPlan.remaining
            : streamingRevealBudget(for: textPlan.remaining + thinkingPlan.remaining)
        let textReveal = reveal(textPlan, budget: &budget)
        let thinkingReveal = reveal(thinkingPlan, budget: &budget)
        var next = current
        next.role = target.role
        next.timestamp = target.timestamp ?? current.timestamp
        next.stopReason = target.stopReason
        next.completedAt = target.completedAt ?? current.completedAt
        next.text = textReveal.value
        next.thinking = thinkingReveal.value
        next.images = target.images
        next.tools = mergeTools(existing: current.tools, incoming: target.tools)
        let revealsText = next.text != current.text || next.thinking != current.thinking
        // A paragraph-mode frame that reveals text stays streaming one more frame,
        // so its text fades in even when the whole reply arrived at once.
        let holdsForFade = revealsText && ResponseStreamingPreference.current == .paragraphs
        let complete = textReveal.complete && thinkingReveal.complete && !holdsForFade
        next.isStreaming = target.isStreaming || !complete
        if revealsText { lastTextRevealAt = Date() }
        if next != current {
            messages[index] = next
            streamingFrameToken += 1
        }
        return complete
    }

    private func applyStreamingMessage(_ message: ChatMessage) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            var updated = message
            updated.tools = mergeTools(existing: messages[index].tools, incoming: message.tools)
            messages[index] = updated
        } else {
            messages.append(message)
        }
        streamingFrameToken += 1
    }

    private func streamingRevealBudget(for remaining: Int) -> Int {
        guard remaining > 0 else { return 0 }
        return min(56, max(2, Int(ceil(Double(remaining) / 18.0))))
    }

    private struct StreamingRevealPlan {
        var base: String
        var remainder: Substring
        var remaining: Int
    }

    private func streamingRevealPlan(from current: String, to target: String) -> StreamingRevealPlan {
        var currentIndex = current.startIndex
        var targetIndex = target.startIndex
        while currentIndex < current.endIndex,
              targetIndex < target.endIndex,
              current[currentIndex] == target[targetIndex] {
            currentIndex = current.index(after: currentIndex)
            targetIndex = target.index(after: targetIndex)
        }

        if targetIndex == target.endIndex {
            return StreamingRevealPlan(base: target, remainder: target[target.endIndex...], remaining: 0)
        }
        let remainder = target[targetIndex...]
        let base = currentIndex == current.endIndex ? current : String(target[..<targetIndex])
        return StreamingRevealPlan(base: base, remainder: remainder, remaining: remainder.count)
    }

    private func reveal(_ plan: StreamingRevealPlan, budget: inout Int) -> (value: String, complete: Bool) {
        guard plan.remaining > 0 else { return (plan.base, true) }
        guard budget > 0 else { return (plan.base, false) }
        let count = revealCount(in: plan.remainder, remainderCount: plan.remaining, budget: budget)
        budget -= count
        return (plan.base + String(plan.remainder.prefix(count)), count == plan.remaining)
    }

    // Reveal whole words where possible. Revealing a fixed number of
    // characters grows the trailing word one glyph at a time, and every one
    // of those glyphs can re-wrap the line, so the paragraph jitters while it
    // streams. Falling back to the raw count keeps very long unbroken tokens
    // (URLs, base64) from stalling the reveal.
    private func revealCount(in remainder: Substring, remainderCount: Int, budget: Int) -> Int {
        let count = min(budget, remainderCount)
        guard count < remainderCount else { return remainderCount }
        let taken = remainder.prefix(count)
        guard let lastBreak = taken.lastIndex(where: { $0.isWhitespace }) else { return count }
        let trimmed = taken.distance(from: taken.startIndex, to: taken.index(after: lastBreak))
        return trimmed >= max(1, count / 4) ? trimmed : count
    }

}
