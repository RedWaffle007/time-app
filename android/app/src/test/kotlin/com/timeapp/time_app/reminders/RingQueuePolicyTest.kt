package com.timeapp.time_app.reminders

import com.timeapp.time_app.reminders.RingQueuePolicy.Alarm
import com.timeapp.time_app.reminders.RingQueuePolicy.Segment
import com.timeapp.time_app.reminders.RingQueuePolicy.Sound
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** DECISIONS.md "Ring queue: new alarms first, repeats fill the gaps" (2026-10-05). */
class RingQueuePolicyTest {
    private val min = 60_000L
    private val sec = 1_000L

    /** 5:00 on some day; [at] gives 5:mm:ss after it. */
    private val five = 1_790_000_000_000L - (1_790_000_000_000L % (60 * min))
    private fun at(minute: Int, second: Int = 0) = five + minute * min + second * sec

    private fun tone(id: String, minute: Int) = Alarm(id, at(minute))
    private fun voice(id: String, minute: Int, seconds: Int = 25) =
        Alarm(id, at(minute), voiceMs = seconds * sec)

    /** What rang, in order: which alarms, which ring, from and to. */
    private data class Rang(val ids: List<String>, val fresh: Boolean, val from: Long, val to: Long)

    private data class Run(val rang: List<Rang>, val missed: List<Pair<String, Long>>)

    /**
     * Drives the policy the way the native queue will: ring the next segment,
     * let a newly arriving alarm interrupt it under the cutting rules, credit
     * what played, and sleep until the next thing is due. [arrivals] are
     * plans that reach the phone at a time (a plan made at the last minute).
     */
    private fun simulate(start: List<Alarm>, arrivals: Map<Long, Alarm> = emptyMap()): Run {
        var alarms = start
        val pending = arrivals.toSortedMap().toMutableMap()
        val rang = mutableListOf<Rang>()
        val missed = mutableListOf<Pair<String, Long>>()
        var now = (alarms.map { it.dueAt } + pending.keys).min()
        repeat(500) {
            pending.keys.filter { it <= now }.forEach { alarms = alarms + pending.remove(it)!! }
            val segment = RingQueuePolicy.nextSegment(alarms, now)
            if (segment == null) {
                val wake = listOfNotNull(RingQueuePolicy.nextWakeAt(alarms, now), pending.keys.minOrNull())
                    .minOrNull() ?: return Run(rang, missed)
                now = wake
                return@repeat
            }
            val scheduledAt = alarms.first { it.itemId == segment.itemIds.first() }.scheduledAt
            // A plan arriving mid-segment that is already due may interrupt.
            val interrupt = pending.entries.firstOrNull { (arrive, alarm) ->
                arrive in (segment.startsAt + 1) until segment.endsAt &&
                    RingQueuePolicy.interrupts(segment, scheduledAt, alarm)
            }
            val end = if (interrupt == null) {
                segment.endsAt
            } else {
                RingQueuePolicy.cutAt(segment, maxOf(interrupt.key, interrupt.value.scheduledAt))
            }
            rang += Rang(segment.itemIds, segment.fresh, segment.startsAt, end)
            val credit = RingQueuePolicy.credit(alarms, segment, end)
            credit.missed.forEach { missed += it to end }
            alarms = credit.alarms.filter { !it.isOver }
            now = end
        }
        error("did not settle")
    }

    @Test
    fun `numbers agreed with the user`() {
        assertEquals(5 * min, RingQueuePolicy.FRESH_MAX_MS)
        assertEquals(2 * min, RingQueuePolicy.REPEAT_MS)
        assertEquals(10 * min, RingQueuePolicy.REPEAT_SPACING_MS)
        assertEquals(3, RingQueuePolicy.RINGS)
        assertEquals(20 * sec, RingQueuePolicy.MIN_TONE_MS)
        assertEquals(3 * sec, RingQueuePolicy.BATCH_VOICE_GAP_MS)
        assertEquals(VoiceAlarmPolicy.REPLAY_GAP_MS, RingQueuePolicy.REPLAY_GAP_MS)
    }

    @Test
    fun `one alarm alone rings 5 minutes, then 2-minute repeats 10 minutes apart`() {
        val run = simulate(listOf(tone("a", 8)))
        assertEquals(
            listOf(
                Rang(listOf("a"), true, at(8), at(13)),
                Rang(listOf("a"), false, at(18), at(20)),
                Rang(listOf("a"), false, at(28), at(30)),
            ),
            run.rang,
        )
        assertEquals(listOf("a" to at(30)), run.missed)
    }

    @Test
    fun `5_08 and 5_09 - the first rings one minute, the second on time`() {
        val run = simulate(listOf(tone("a", 8), tone("b", 9)))
        assertEquals(Rang(listOf("a"), true, at(8), at(9)), run.rang[0])
        assertEquals(Rang(listOf("b"), true, at(9), at(14)), run.rang[1])
        // Repeats are due 10 minutes after each ring STARTED: 5:18 and 5:19.
        assertEquals(Rang(listOf("a"), false, at(18), at(20)), run.rang[2])
        assertEquals(Rang(listOf("b"), false, at(20), at(22)), run.rang[3])
    }

    @Test
    fun `a new alarm on a repeat's minute rings on time and the repeats batch after it`() {
        // The user's example on the agreed +10 rule: repeats due 5:18 / 5:19,
        // and someone plans 5:18.
        val run = simulate(listOf(tone("a", 8), tone("b", 9), tone("x", 18)))
        assertEquals(Rang(listOf("x"), true, at(18), at(23)), run.rang[2])
        assertEquals(Rang(listOf("a", "b"), false, at(23), at(25)), run.rang[3])
        // Both repeats started together at 5:23, so both are next due 5:33.
        assertEquals(Rang(listOf("a", "b"), false, at(33), at(35)), run.rang[5])
    }

    @Test
    fun `no cut-off - both repeats happen however far they are pushed`() {
        // A new alarm every minute for 90 minutes holds "a"'s repeats back.
        val busy = (9 until 99).map { tone("f$it", it) }
        val run = simulate(listOf(tone("a", 8)) + busy)
        val aRings = run.rang.filter { "a" in it.ids }
        assertEquals(3, aRings.size)
        assertTrue(aRings.last().from > at(98))
        assertTrue(run.missed.any { it.first == "a" })
    }

    @Test
    fun `user unavailable comes after the last repeat, not at a fixed time`() {
        val busy = (9 until 40).map { tone("f$it", it) }
        val run = simulate(listOf(tone("a", 8)) + busy)
        val lastRing = run.rang.last { "a" in it.ids }
        assertEquals(lastRing.to, run.missed.first { it.first == "a" }.second)
    }

    @Test
    fun `a voice note plays twice in a 1-minute ring, never started past the next minute`() {
        val segment = RingQueuePolicy.planFresh(voice("v", 8), at(8), at(9))
        assertEquals(
            listOf(
                Sound.Voice("v", at(8), at(8, 25)),
                Sound.Voice("v", at(8, 26), at(8, 51)),
            ),
            segment.sounds,
        )
    }

    @Test
    fun `a late voice note is never cut - the next alarm waits for the play to end`() {
        // 5:08 delivered 40 s late; 5:09's alarm reaches its time mid-play.
        val late = RingQueuePolicy.planFresh(voice("v", 8), at(8, 40), at(9))
        assertEquals(listOf(Sound.Voice("v", at(8, 40), at(9, 5))), late.sounds)
        assertEquals(at(9, 5), RingQueuePolicy.cutAt(late, at(9)))
    }

    @Test
    fun `a tone may be cut only after 20 seconds`() {
        val late = RingQueuePolicy.planFresh(tone("a", 8), at(8, 50), at(9))
        assertEquals(listOf(Sound.Tone(listOf("a"), at(8, 50), at(9, 10))), late.sounds)
        assertEquals(at(9, 10), RingQueuePolicy.cutAt(late, at(9)))
        val onTime = RingQueuePolicy.planFresh(tone("a", 8), at(8), null)
        assertEquals(at(9), RingQueuePolicy.cutAt(onTime, at(9)))
    }

    @Test
    fun `a plan arriving at the last minute interrupts a repeat once its tone rang 20 s`() {
        // "a" repeats at 5:18; a plan for 5:18:10 reaches the phone at 5:18:10.
        val run = simulate(
            listOf(tone("a", 8)),
            arrivals = mapOf(at(18, 10) to Alarm("x", at(18, 10))),
        )
        assertEquals(Rang(listOf("a"), false, at(18), at(18, 20)), run.rang[1])
        assertEquals(Rang(listOf("x"), true, at(18, 20), at(23, 20)), run.rang[2])
        // 20 s of tone counted as "a"'s second ring.
        assertEquals(2, run.rang.count { "a" in it.ids && !it.fresh })
    }

    @Test
    fun `a repeat cut before 20 s does not count and stays due`() {
        val segment = RingQueuePolicy.planRepeats(
            listOf(Alarm("a", at(8), ringsDone = 1, lastRingAt = at(8))),
            at(18),
            null,
        )!!
        val credit = RingQueuePolicy.credit(
            listOf(Alarm("a", at(8), ringsDone = 1, lastRingAt = at(8))),
            segment,
            at(18, 19),
        )
        assertEquals(1, credit.alarms.single().ringsDone)
        assertTrue(credit.missed.isEmpty())
    }

    @Test
    fun `a new alarm interrupts repeats and newer new alarms, never an older late one`() {
        val repeats = Segment(false, listOf("a"), listOf(Sound.Tone(listOf("a"), at(18), at(20))))
        val ringing = Segment(true, listOf("b"), listOf(Sound.Tone(listOf("b"), at(9), at(14))))
        assertTrue(RingQueuePolicy.interrupts(repeats, at(8), tone("x", 19)))
        assertTrue(RingQueuePolicy.interrupts(ringing, at(9), tone("x", 10)))
        assertFalse(RingQueuePolicy.interrupts(ringing, at(9), tone("late", 8)))
        assertFalse(
            RingQueuePolicy.interrupts(
                repeats,
                at(8),
                Alarm("r", at(7), ringsDone = 1, lastRingAt = at(7)),
            ),
        )
    }

    @Test
    fun `two late new alarms - the one scheduled latest rings first`() {
        val segment = RingQueuePolicy.nextSegment(listOf(tone("a", 8), tone("b", 9)), at(12))!!
        assertEquals(listOf("b"), segment.itemIds)
    }

    @Test
    fun `a batch plays voice notes first, 3 s apart, then one tone for the rest`() {
        val due = listOf(
            Alarm("t1", at(1), ringsDone = 1, lastRingAt = at(1)),
            Alarm("v1", at(2), voiceMs = 25 * sec, ringsDone = 1, lastRingAt = at(2)),
            Alarm("v2", at(3), voiceMs = 20 * sec, ringsDone = 1, lastRingAt = at(3)),
            Alarm("t2", at(4), ringsDone = 1, lastRingAt = at(4)),
        )
        val segment = RingQueuePolicy.planRepeats(due, at(20), null)!!
        assertEquals(
            listOf(
                Sound.Voice("v1", at(20), at(20, 25)),
                Sound.Voice("v2", at(20, 28), at(20, 48)),
                Sound.Tone(listOf("t1", "t2"), at(20, 51), at(22)),
            ),
            segment.sounds,
        )
        assertEquals(listOf("v1", "v2", "t1", "t2"), segment.itemIds)
    }

    @Test
    fun `five voice notes each play once even past 2 minutes`() {
        val due = (1..5).map { Alarm("v$it", at(it), voiceMs = 25 * sec, ringsDone = 1, lastRingAt = at(it)) }
        val segment = RingQueuePolicy.planRepeats(due, at(20), null)!!
        assertEquals(5, segment.sounds.size)
        assertEquals(at(22, 17), segment.endsAt) // 5 × 25 s + 4 × 3 s
    }

    @Test
    fun `a voice-only batch goes round again until 2 minutes`() {
        val due = listOf(Alarm("v", at(8), voiceMs = 25 * sec, ringsDone = 1, lastRingAt = at(8)))
        val segment = RingQueuePolicy.planRepeats(due, at(18), null)!!
        // 0-25, 28-53, 56-81, 84-109 s; a fifth play would end at 137 s.
        assertEquals(4, segment.sounds.size)
        assertEquals(at(19, 49), segment.endsAt)
        assertEquals(listOf("v"), segment.itemIds)
    }

    @Test
    fun `mixed batch past 2 minutes still gives the tone 20 s`() {
        val due = (1..5).map { Alarm("v$it", at(it), voiceMs = 25 * sec, ringsDone = 1, lastRingAt = at(it)) } +
            Alarm("t", at(6), ringsDone = 1, lastRingAt = at(6))
        val segment = RingQueuePolicy.planRepeats(due, at(20), null)!!
        assertEquals(Sound.Tone(listOf("t"), at(22, 20), at(22, 40)), segment.sounds.last())
    }

    @Test
    fun `repeats never start a note or tone that would delay the next new alarm`() {
        val due = listOf(
            Alarm("v", at(1), voiceMs = 25 * sec, ringsDone = 1, lastRingAt = at(1)),
            Alarm("t", at(2), ringsDone = 1, lastRingAt = at(2)),
        )
        // 15 s before the next new alarm: neither a 25 s note nor 20 s of tone fits.
        assertNull(RingQueuePolicy.planRepeats(due, at(20, 45), at(21)))
        // 40 s: the note fits; the tone after it (from 28 s) gets only 12 s.
        val segment = RingQueuePolicy.planRepeats(due, at(20, 20), at(21))!!
        assertEquals(listOf("v"), segment.itemIds)
        // The tone stays due; the queue looks again when the new alarm is due.
        assertEquals(at(21), RingQueuePolicy.nextWakeAt(due + tone("x", 21), at(20, 45)))
    }

    @Test
    fun `a note a new alarm cut off stays due`() {
        val due = listOf(
            Alarm("v1", at(1), voiceMs = 25 * sec, ringsDone = 1, lastRingAt = at(1)),
            Alarm("v2", at(2), voiceMs = 25 * sec, ringsDone = 1, lastRingAt = at(2)),
        )
        val segment = RingQueuePolicy.planRepeats(due, at(20), null)!!
        // A plan arriving at 5:20:30 cuts in after v2's play (5:20:28-53).
        val end = RingQueuePolicy.cutAt(segment, at(20, 30))
        assertEquals(at(20, 53), end)
        val credit = RingQueuePolicy.credit(due, segment, at(20, 27))
        assertEquals(listOf(2, 1), credit.alarms.map { it.ringsDone })
    }

    @Test
    fun `birthday - a voice note every minute each rings at its own minute`() {
        val notes = (0 until 10).map { voice("n$it", 10 + it) }
        val run = simulate(notes)
        val firsts = run.rang.filter { it.fresh }
        assertEquals((0 until 10).map { at(10 + it) }, firsts.map { it.from })
        assertTrue(firsts.dropLast(1).all { it.to <= it.from + min })
        assertEquals(10, run.missed.size)
    }

    @Test
    fun `forecast - when each waiting alarm rings next, after what rings now`() {
        val alarms = listOf(
            Alarm("a", at(8), ringsDone = 1, lastRingAt = at(8)),
            Alarm("b", at(9), ringsDone = 1, lastRingAt = at(9)),
            tone("x", 18),
        )
        // x takes 5:18; a and b wait for it and ring together at 5:23.
        assertEquals(
            mapOf("x" to at(18), "a" to at(23), "b" to at(23)),
            RingQueuePolicy.forecast(alarms, at(14)),
        )
        // While x rings, x's own next ring is its first repeat.
        val ringing = RingQueuePolicy.nextSegment(alarms, at(18))!!
        assertEquals(at(28), RingQueuePolicy.forecast(alarms, at(19), ringing)["x"])
    }
}
