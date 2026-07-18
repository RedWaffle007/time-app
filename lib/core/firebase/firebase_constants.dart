/// The Firebase "web" OAuth client ID (client_type 3 in google-services.json).
///
/// google_sign_in v7 needs this passed as `serverClientId` so the ID token it
/// returns is scoped for Firebase Auth (correct audience). It is NOT a secret —
/// OAuth client IDs are public identifiers.
const String kGoogleServerClientId =
    '1017134330881-16gfitlitb64qi43lmuteovv9gdts17h.apps.googleusercontent.com';
