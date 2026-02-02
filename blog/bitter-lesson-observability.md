# The Bitter Lesson Comes for Observability

Richard Sutton's 2019 essay "The Bitter Lesson" makes a simple but uncomfortable observation: over 70 years of AI research, the methods that win are the ones that leverage computation at scale, not the ones that try to be clever about encoding human knowledge.

Chess engines that search more positions beat chess engines with better heuristics. Speech recognition systems that train on more data beat systems with hand-crafted phoneme models. The lesson is bitter because it means a lot of careful human engineering—often representing genuine insight—gets steamrolled by brute force and Moore's Law.

What does this have to do with database monitoring?

## The Old Calculus

Traditional observability tools are monuments to human curation. They exist because human attention is expensive and limited. You can't show a DBA 500 metrics and expect them to find the signal. So the tools get smart:

- **Thresholds**: Alert when connections exceed 80%
- **Aggregations**: Roll up per-second data into 5-minute buckets
- **Dashboards**: Show the 12 metrics that usually matter
- **Anomaly detection**: Learn what's "normal" and surface deviations

This curation represents genuine expertise. Someone who's debugged a thousand databases knows that `bgwriter_buffers_backend` spiking usually means shared_buffers is too small. That knowledge gets baked into the tool: a red light appears when the metric crosses a threshold.

But this approach has costs:

1. **Implicit assumptions** :: The thresholds encode what *usually* matters, which may not be what matters for *your* workload
2. **Lost signal** :: Pre-aggregation destroys information that might have been diagnostic
3. **Brittleness** :: The system catches problems the designers anticipated, and misses the ones they didn't
4. **Expertise bottleneck** :: The tool is only as good as the knowledge encoded in it

## The New Calculus

When AI enters the picture, the economics shift.

Human attention is still expensive. But AI attention is cheap. An LLM can read through hours of telemetry data, correlate across dimensions, and surface hypotheses—tasks that would take a human analyst significant time. The bottleneck moves from "what can a human absorb?" to "what data is available to analyze?"

This changes the optimal design point for monitoring tools.

The old question: *What should we show the human?*
The new question: *What should we record for the AI?*

These have different answers. A human needs a dashboard with carefully chosen visualizations. An AI needs structured data with timestamps and the ability to ask arbitrary questions. A human needs pre-computed anomaly scores. An AI can compute its own anomalies from raw data—and might define "anomaly" differently depending on the question being asked.

## Flight Recorders, Not Dashboards

The "flight recorder" metaphor is instructive. Aviation crash investigators don't rely on dashboards that some engineer thought would be useful. They rely on comprehensive recordings of what actually happened—altitude, airspeed, control inputs, voice communications—and they reconstruct the story afterward.

This works because:

1. **You can't anticipate every failure mode** — The interesting crashes are the ones nobody predicted
2. **Context matters** — The same metric can be fine or catastrophic depending on what else is happening
3. **Hindsight is 20/20** — Once you know what went wrong, you know what data you needed

Database incidents work the same way. The "obvious" metrics often aren't the ones that matter. Was it a configuration change? A query plan regression? A locking chain that built up over 20 minutes? You often don't know what question to ask until you're deep into the investigation.

A flight recorder approach inverts the traditional design:

| Traditional | Flight Recorder |
|-------------|-----------------|
| Curate at collection time | Record comprehensively |
| Aggregate for storage efficiency | Retain raw data (within limits) |
| Pre-compute what matters | Analyze at query time |
| Optimize for human consumption | Optimize for machine analysis |

## The Bitter Part

Here's where Sutton's lesson bites.

All that careful curation in traditional monitoring tools? The hand-tuned thresholds, the expertly chosen default dashboards, the anomaly detection algorithms calibrated on years of operational experience?

It might get outcompeted by dumber systems that just record more and let AI figure it out.

This is bitter because the curation represents real expertise. Someone who sets a threshold at 80% instead of 75% might be encoding hard-won knowledge from a production incident. That's valuable! But it's valuable in the same way that hand-crafted chess heuristics were valuable—right up until search got fast enough that you didn't need them.

The general method (record everything, analyze with compute) tends to beat the special method (encode expertise in the tool) as compute gets cheaper. We've seen this movie before.

## What This Means in Practice

If you're building monitoring tools today, consider:

**1. Bias toward retention over curation.** Storage is cheap. The data you don't record is the data you can't analyze later. When in doubt, keep it.

**2. Expose raw data, not just summaries.** Dashboards are still useful for humans, but make sure the underlying data is accessible for programmatic analysis. A `report()` function might be more valuable than a pretty graph.

**3. Timestamps and structure matter.** AI can handle volume, but it needs data to be structured and temporally coherent. "What was the configuration when the incident started?" requires that configuration changes are recorded with timestamps.

**4. Don't pre-aggregate too aggressively.** Rolling up per-second data to 5-minute buckets saves storage but destroys information. A spike that lasted 30 seconds disappears into an average. Consider tiered retention: high-frequency recent data, aggregated historical data.

**5. Think about the AI as a user.** What would an AI need to diagnose a problem? Probably not a PNG of a graph. Probably structured data with clear semantics and the ability to query arbitrary time ranges.

## Record Comprehensively, Present Hierarchically

A caveat before we get too enthusiastic about "record everything."

AI attention is cheaper than human attention, but it isn't infinite. Context windows have limits. More importantly, signal-to-noise ratio still matters. An AI drowning in irrelevant data can lose the signal just like a human can—it just takes more noise to get there.

This suggests some countervailing principles:

**Low order methods first.** Start with simple aggregates: connection count, query rate, error rate. If these look normal, you may not need to dig deeper. Don't reach for the detailed wait event analysis when the summary shows nothing unusual.

**Top down, not bottom up.** Begin with the summary, not the raw data. "3 anomalies detected in the last hour" is a better starting point than "here are 50,000 rows of telemetry." The detail exists to explain the summary, not replace it.

**Recursive refinement.** Let the investigator—human or AI—pull the thread. "Tell me more about that lock contention at 14:03" fetches relevant detail on demand. The system doesn't dump everything; it responds to questions.

**Progressive reveal.** Structure the data in layers. A `report()` function that surfaces likely-relevant information is more useful than a raw table dump, even if both contain the same underlying data. The layers guide attention toward signal.

The key distinction: *record* comprehensively, but *present* hierarchically.

The flight recorder captures everything, but the crash investigator doesn't read every byte of every channel simultaneously. They start with the summary—loss of altitude at timestamp T—then drill into control inputs, then engine telemetry, then voice recordings. Each layer adds detail to explain what the previous layer surfaced.

For database monitoring, this means the raw data should be queryable, not just dumpable. An AI that can ask "show me wait events between 14:02 and 14:05 for queries touching the orders table" will outperform one that receives the entire wait event history and is told "find the problem." The comprehensive recording enables the precise query; it doesn't replace the need for precision.

## The Opportunity

The flip side of "bitter" is "opportunity." If general methods win, then the teams that embrace them early get an advantage.

A database with comprehensive telemetry—wait events, lock chains, query stats, configuration history, table-level activity—becomes dramatically easier to troubleshoot when you can point an AI at it. The AI doesn't care that there are 50 tables in `table_snapshots`. It will read them all, correlate with the timestamp of the incident, and tell you that `orders` table started getting seq-scanned right after someone changed `random_page_cost`.

The monitoring tool that "just records everything" starts looking less like a limitation and more like a feature. It's not dumb—it's general. And general methods scale.

## Conclusion

The Bitter Lesson isn't that human expertise doesn't matter. It's that human expertise embedded in *systems* tends to get outcompeted by human expertise *using* general-purpose tools with more compute.

The DBA's knowledge of what causes buffer pressure is still valuable. But it might be more valuable as context provided to an AI analyzing raw telemetry than as a threshold hardcoded in a monitoring tool.

We're early in this transition. Most monitoring tools are still optimized for human eyeballs, and that's fine—humans still need to make decisions. But the tools that will age well are probably the ones that also work as "flight recorders": comprehensive, structured, queryable. Record now, analyze later, with whatever intelligence is available at analysis time.

The lesson is bitter, but the future is interesting.
