// fcm-rest.js — Worker transport for `ctx.fcm`, backed by the FCM HTTP v1 API.
// One send per token; maps FCM's error shape to the small vocabulary notify.js
// acts on (UNREGISTERED / INVALID → clean the token; OTHER → leave it).

export function makeFcm(projectId, accessToken) {
  const url = `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`;

  return {
    async send(token, message) {
      const resp = await fetch(url, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${accessToken}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ message: { token, ...message } }),
      });
      if (resp.ok) return { ok: true };

      let errorCode = 'OTHER';
      try {
        const body = await resp.json();
        const detail = (body.error?.details || []).find(
          (d) => typeof d.errorCode === 'string',
        );
        const code = detail?.errorCode || body.error?.status;
        if (code === 'UNREGISTERED') errorCode = 'UNREGISTERED';
        else if (code === 'INVALID_ARGUMENT' || code === 'SENDER_ID_MISMATCH') {
          errorCode = 'INVALID';
        }
      } catch {
        // Non-JSON error body → treat as transient OTHER.
      }
      return { error: errorCode };
    },
  };
}
