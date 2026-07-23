/// Cloudflare Worker endpoint for the completion→planner push (client-triggered
/// transport; see DECISIONS.md → "Completion→planner push").
///
/// NOT a secret — auth is the Firebase ID-token check on the Worker, not URL
/// secrecy. Fill this in after `wrangler deploy` prints the URL. While it is
/// empty the app no-ops the call (the in-app outcomes view still works), so the
/// build runs before the Worker is deployed.
const String kNotifyEndpoint = 'https://time-app-notify.timeapp.workers.dev';
