// firestore-rest.js — Worker transport for `ctx.db`, backed by the Firestore
// REST API and authed with the service-account access token. A future Cloud
// Function would provide the SAME `db` shape over the Admin SDK instead; notify.js
// doesn't know or care which.

const BASE = (projectId) =>
  `https://firestore.googleapis.com/v1/projects/${projectId}/databases/(default)/documents`;

function itemFilter(fieldPath, op, value) {
  return { fieldFilter: { field: { fieldPath }, op, value } };
}

export function makeFirestoreDb(projectId, accessToken) {
  const base = BASE(projectId);
  const authHeader = { Authorization: `Bearer ${accessToken}` };

  const urlFor = (path) =>
    `${base}/${path.split('/').map(encodeURIComponent).join('/')}`;

  // Collection-group query over every target's `items`, soonest first.
  async function queryItems(filters, limit) {
    const resp = await fetch(`${base}:runQuery`, {
      method: 'POST',
      headers: { ...authHeader, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        structuredQuery: {
          from: [{ collectionId: 'items', allDescendants: true }],
          where: { compositeFilter: { op: 'AND', filters } },
          orderBy: [{
            field: { fieldPath: 'scheduledInstantUtc' },
            direction: 'ASCENDING',
          }],
          limit,
        },
      }),
    });
    if (!resp.ok) throw new Error(`Firestore items query → ${resp.status}`);
    const rows = await resp.json();
    const marker = '/documents/';
    return rows
      .filter((row) => row.document)
      .map((row) => {
        const name = row.document.name;
        const at = name.indexOf(marker);
        return {
          path: at >= 0
            ? name.slice(at + marker.length).split('/').map(decodeURIComponent).join('/')
            : '',
          data: decodeFields(row.document.fields),
          updateTime: row.document.updateTime,
          createTime: row.document.createTime,
        };
      });
  }

  return {
    async getDoc(path) {
      const resp = await fetch(urlFor(path), { headers: authHeader });
      if (resp.status === 404) return null;
      if (!resp.ok) throw new Error(`Firestore getDoc ${path} → ${resp.status}`);
      const doc = await resp.json();
      return decodeFields(doc.fields);
    },

    async listDocIds(collectionPath) {
      const resp = await fetch(`${urlFor(collectionPath)}?pageSize=100`, {
        headers: authHeader,
      });
      if (resp.status === 404) return [];
      if (!resp.ok) {
        throw new Error(`Firestore list ${collectionPath} → ${resp.status}`);
      }
      const json = await resp.json();
      const docs = json.documents || [];
      // The doc id is the last segment of the resource name; decode the percent
      // escaping so the returned FCM token is the raw value again.
      return docs.map((d) => decodeURIComponent(d.name.split('/').pop()));
    },

    async deleteDoc(path) {
      const resp = await fetch(urlFor(path), {
        method: 'DELETE',
        headers: authHeader,
      });
      // 404 = already gone; treat as success.
      if (!resp.ok && resp.status !== 404) {
        throw new Error(`Firestore delete ${path} → ${resp.status}`);
      }
    },

    async patchDoc(path, fields) {
      const mask = Object.keys(fields)
        .map((k) => `updateMask.fieldPaths=${encodeURIComponent(k)}`)
        .join('&');
      const resp = await fetch(`${urlFor(path)}?${mask}`, {
        method: 'PATCH',
        headers: { ...authHeader, 'Content-Type': 'application/json' },
        body: JSON.stringify({ fields: encodeFields(fields) }),
      });
      if (!resp.ok) throw new Error(`Firestore patch ${path} → ${resp.status}`);
    },

    async patchDocIfUnchanged(path, fields, updateTime) {
      const mask = Object.keys(fields)
        .map((k) => `updateMask.fieldPaths=${encodeURIComponent(k)}`)
        .join('&');
      const precondition = `currentDocument.updateTime=${encodeURIComponent(updateTime)}`;
      const resp = await fetch(`${urlFor(path)}?${mask}&${precondition}`, {
        method: 'PATCH',
        headers: { ...authHeader, 'Content-Type': 'application/json' },
        body: JSON.stringify({ fields: encodeFields(fields) }),
      });
      // Another app interaction or cron invocation won the race.
      if (resp.status === 409 || resp.status === 412) return false;
      if (resp.status === 400) {
        try {
          const body = await resp.clone().json();
          if (body.error?.status === 'FAILED_PRECONDITION') return false;
        } catch {
          // Fall through to the ordinary transport error below.
        }
      }
      if (!resp.ok) {
        throw new Error(`Firestore conditional patch ${path} → ${resp.status}`);
      }
      return true;
    },

    // Pending schedule items due after `now`, soonest first, across every
    // target (collection group; composite index status+scheduledInstantUtc).
    async listPendingItems(now, limit = 50) {
      return queryItems([
        itemFilter('status', 'EQUAL', { stringValue: 'pending' }),
        itemFilter('scheduledInstantUtc', 'GREATER_THAN',
          { timestampValue: now.toISOString() }),
      ], limit);
    },

    // Items with [status] scheduled in (fromIso, toIso], soonest first. Same
    // composite index; used by the server-side lapse.
    async listItemsScheduledBetween(status, fromIso, toIso, limit = 100) {
      return queryItems([
        itemFilter('status', 'EQUAL', { stringValue: status }),
        itemFilter('scheduledInstantUtc', 'GREATER_THAN', { timestampValue: fromIso }),
        itemFilter('scheduledInstantUtc', 'LESS_THAN_OR_EQUAL', { timestampValue: toIso }),
      ], limit);
    },

    // voiceUploads whose expiresAt has passed, oldest first (voice.js sweep).
    async listDueVoiceUploads(now, limit = 15) {
      const resp = await fetch(`${base}:runQuery`, {
        method: 'POST',
        headers: { ...authHeader, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          structuredQuery: {
            from: [{ collectionId: 'voiceUploads' }],
            where: itemFilter('expiresAt', 'LESS_THAN_OR_EQUAL',
              { timestampValue: now.toISOString() }),
            orderBy: [{ field: { fieldPath: 'expiresAt' }, direction: 'ASCENDING' }],
            limit,
          },
        }),
      });
      if (!resp.ok) throw new Error(`Firestore voiceUploads query → ${resp.status}`);
      const rows = await resp.json();
      return rows
        .filter((row) => row.document)
        .map((row) => ({
          id: decodeURIComponent(row.document.name.split('/').pop()),
          data: decodeFields(row.document.fields),
        }));
    },

    async listDueInactivityStates(now, limit = 100) {
      const resp = await fetch(`${base}:runQuery`, {
        method: 'POST',
        headers: { ...authHeader, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          structuredQuery: {
            from: [{ collectionId: 'inactivityStates' }],
            where: {
              fieldFilter: {
                field: { fieldPath: 'nextNotificationAt' },
                op: 'LESS_THAN_OR_EQUAL',
                value: { timestampValue: now.toISOString() },
              },
            },
            orderBy: [{
              field: { fieldPath: 'nextNotificationAt' },
              direction: 'ASCENDING',
            }],
            limit,
          },
        }),
      });
      if (!resp.ok) throw new Error(`Firestore inactivity query → ${resp.status}`);
      const rows = await resp.json();
      return rows
        .filter((row) => row.document)
        .map((row) => ({
          id: decodeURIComponent(row.document.name.split('/').pop()),
          data: decodeFields(row.document.fields),
          updateTime: row.document.updateTime,
        }));
    },
  };
}

// --- minimal Firestore REST value codec (only the types this app uses) ---

function decodeFields(fields) {
  const out = {};
  if (!fields) return out;
  for (const [k, v] of Object.entries(fields)) out[k] = decodeValue(v);
  return out;
}

function decodeValue(v) {
  if (v == null) return null;
  if ('stringValue' in v) return v.stringValue;
  if ('booleanValue' in v) return v.booleanValue;
  if ('integerValue' in v) return Number(v.integerValue);
  if ('doubleValue' in v) return v.doubleValue;
  if ('timestampValue' in v) return v.timestampValue; // ISO string
  if ('nullValue' in v) return null;
  if ('mapValue' in v) return decodeFields(v.mapValue.fields);
  if ('arrayValue' in v) return (v.arrayValue.values || []).map(decodeValue);
  if ('referenceValue' in v) return v.referenceValue;
  return null; // unhandled types collapse to null (we don't use them)
}

// Write types used by notification policy.
function encodeFields(obj) {
  const out = {};
  for (const [k, val] of Object.entries(obj)) out[k] = encodeValue(val);
  return out;
}

function encodeValue(val) {
  if (val instanceof Date) return { timestampValue: val.toISOString() };
  if (typeof val === 'string') return { stringValue: val };
  if (typeof val === 'boolean') return { booleanValue: val };
  // Whole numbers are written as integers so the rules' `is int` checks and
  // the app's int parsing see what they expect.
  if (typeof val === 'number') {
    return Number.isInteger(val)
      ? { integerValue: String(val) }
      : { doubleValue: val };
  }
  if (val == null) return { nullValue: null };
  if (typeof val === 'object' && !Array.isArray(val)) {
    return { mapValue: { fields: encodeFields(val) } };
  }
  throw new Error(`encodeValue: unsupported type for ${val}`);
}
