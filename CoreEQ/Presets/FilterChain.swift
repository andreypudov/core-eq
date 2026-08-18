import Foundation

/// Arithmetic on a chain of filters, with no opinion about who owns it.
///
/// These were static methods on `ProfileManager`, which made a manager the place
/// you had to go to ask what a chain *is*. They are properties of the chain
/// itself: the shape it must hold, and what the tone controls do to it. Moving
/// them here leaves the manager doing only what a manager should — deciding when
/// things happen — and lets these be read and tested without one.
enum FilterChain {
    /// Rewrites any chain into the invariant shape: exactly `BuiltInProfiles`'
    /// band count of ladder filters in slot order, then the free filters.
    ///
    /// This invariant is what lets the slider strip index straight into the
    /// array and the graph take its anchors from the ladder rather than deriving
    /// them, so everything downstream depends on it holding.
    ///
    /// Every band's frequency and Q come from the ladder rather than from the
    /// stored value, so a preset saved under an earlier ladder cannot keep stale
    /// centre frequencies and label its slider differently from every other
    /// preset. Free filters are capped so a hand-edited defaults entry cannot
    /// push the chain past the render budget.
    static func normalized(_ filters: [EQFilter]) -> [EQFilter] {
        var bands = BuiltInProfiles.emptyBandChain()
        var free: [EQFilter] = []

        for filter in filters {
            if let slot = filter.band, bands.indices.contains(slot) {
                bands[slot].gain = filter.gain.clamped(to: BuiltInProfiles.gainRange)
                // Deliberately *not* carried over: nothing can switch a ladder
                // band off any more, so a chain saved while the graphic half was
                // bypassed would be silent with no way back. A band at 0 dB is
                // identity, which is what "off" meant for a rung anyway.
                bands[slot].isEnabled = true
            } else if free.count < BuiltInProfiles.maxFreeFilters {
                var loose = filter.unbound()
                loose.frequency = loose.frequency.clamped(to: BuiltInProfiles.filterFrequencyRange)
                loose.gain = loose.gain.clamped(to: BuiltInProfiles.gainRange)
                loose.q = loose.q.clamped(to: BuiltInProfiles.filterQRange)
                free.append(loose)
            }
        }
        return bands + free
    }

    /// The chain `filters` becomes with the tone controls applied to its ladder.
    /// Free filters pass through untouched: the tone controls are a shortcut into
    /// the ladder, not into the whole chain.
    static func applyingTone(
        bass: Double, mid: Double, treble: Double, to filters: [EQFilter]
    ) -> [EQFilter] {
        var chain = filters
        let offsets = QuickTone.offsets(bass: bass, mid: mid, treble: treble)
        for slot in 0..<min(BuiltInProfiles.bandCount, chain.count) {
            chain[slot].gain = (chain[slot].gain + offsets[slot]).clamped(
                to: BuiltInProfiles.gainRange)
        }
        return chain
    }
}
