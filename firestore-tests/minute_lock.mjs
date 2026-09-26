// Batch G item 4 (strict no-double-booking): every schedule-item create must
// arrive in the same write as the lock on its minute. These helpers make a
// client-side plan the way ScheduleRepository.createItem does — item + lock in
// one batch — so tests exercise the real shape.

import { collection, doc, writeBatch } from 'firebase/firestore';

/** Whole minutes since the epoch, as the rules compute it. */
export function epochMinute(instant) {
  const ms = instant instanceof Date ? instant.getTime() : instant.toMillis();
  return String(Math.floor(ms / 60000));
}

export function lockPath(targetUid, instant) {
  return `scheduleMinutes/${targetUid}/minutes/${epochMinute(instant)}`;
}

/** Create the item at [path] with its minute lock, as [db]'s user. */
export function plan(db, path, data) {
  const [, targetUid, , itemId] = path.split('/');
  const batch = writeBatch(db);
  batch.set(doc(db, path), data);
  if (data && data.scheduledInstantUtc) {
    batch.set(doc(db, lockPath(targetUid, data.scheduledInstantUtc)), {
      targetUid,
      itemId,
      createdByUid: data.createdByUid,
      createdAt: new Date(),
    });
  }
  return batch.commit();
}

/** Like `addDoc` on a target's items: a fresh id, item + lock. */
export function planIn(db, targetUid, data) {
  const id = doc(collection(db, 'scheduleItems', targetUid, 'items')).id;
  return plan(db, `scheduleItems/${targetUid}/items/${id}`, data);
}
