import assert from 'node:assert/strict';
import test from 'node:test';

import {
  buildPlannerLapseMessage,
  buildTargetLapseMessage,
  responseDeadlineMs,
  VOICE_RESPONSE_WINDOW_MS,
} from '../src/lapse.js';
import { buildMessage, isVoiceAlarm } from '../src/notify.js';

// Voice notes without Done/Skip (2026-09-28): dismissed while ringing =
// heard; rang out = missed; Play / Already heard = heard late; 24 h
// unanswered = missed.

const voice = {
  title: 'Voice note',
  targetUid: 'target',
  createdByUid: 'planner',
  voiceNote: { durationMs: 8000 },
  scheduledInstantUtc: '2030-10-04T18:00:00Z',
};
const plain = { ...voice, title: 'Gym', voiceNote: undefined };
const names = { actorName: 'Test Target', groupName: null };
const body = (event, subtype, item, n = names) =>
  buildMessage(event, subtype, item, 'target', 'item-1', n).notification;

test('only a voice note someone else sent is a voice alarm', () => {
  assert.equal(isVoiceAlarm(voice), true);
  assert.equal(isVoiceAlarm({ ...voice, createdByUid: 'target' }), false);
  assert.equal(isVoiceAlarm(plain), false);
  assert.equal(isVoiceAlarm(null), false);
});

test('dismissed while ringing: "{Y} heard your voice note."', () => {
  assert.deepEqual(body('dismissed', undefined, voice), {
    title: 'Voice note heard',
    body: 'Test Target heard your voice note.',
  });
  assert.equal(
    body('dismissed', undefined, voice, { actorName: 'Test Target', groupName: 'Team' }).body,
    'Test Target heard your voice note in Team.',
  );
  // A default alarm keeps its wording.
  assert.equal(body('dismissed', undefined, plain).body,
    'Test Target dismissed the alarm for Gym');
});

test('rang out: "{Y} missed your voice note."', () => {
  assert.deepEqual(body('unavailable', undefined, voice), {
    title: 'Test Target missed your voice note',
    body: 'Test Target missed your voice note.',
  });
  assert.equal(body('unavailable', undefined, plain).body,
    'Test Target was unavailable to dismiss the task: Gym you planned for them.');
});

test('Play / Already heard after a missed ring: heard late', () => {
  const rangOut = { ...voice, alarm: { unavailableAt: '2030-10-04T18:01:00Z' } };
  assert.deepEqual(body('outcome', 'done', rangOut), {
    title: 'Voice note heard late',
    body: 'Test Target heard your voice note late.',
  });
  // A default alarm still reads "completed … late".
  assert.match(body('outcome', 'done', { ...plain, alarm: rangOut.alarm }).title,
    /completed late/);
});

test('a voice note closes 24 h after its alarm, not at the end of its day', () => {
  const at = Date.parse('2030-10-04T18:00:00Z');
  assert.equal(responseDeadlineMs(at, 'UTC', { voice: true }), at + VOICE_RESPONSE_WINDOW_MS);
  assert.equal(VOICE_RESPONSE_WINDOW_MS, 24 * 60 * 60 * 1000);
  assert.equal(responseDeadlineMs(at, 'UTC'), Date.parse('2030-10-05T00:00:00Z'));
});

test('the 24-hour close notices speak of the voice note', () => {
  const t = buildTargetLapseMessage(voice, {
    plannerName: 'Test Planner', groupName: null, selfPlanned: false,
  }, 'target', 'item-1');
  assert.equal(t.notification.title, 'Voice note missed');
  assert.equal(t.notification.body,
    "Test Planner's voice note was marked missed because you didn't answer it within 24 hours.");
  const p = buildPlannerLapseMessage(voice, {
    targetName: 'Test Target', groupName: 'Team',
  }, 'target', 'item-1');
  assert.equal(p.notification.body,
    "Test Target didn't answer your voice note in Team within 24 hours.");
});
