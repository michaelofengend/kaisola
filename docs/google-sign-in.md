# Firebase-backed Google sign-in

Kaisola's desktop login is a three-step chain:

1. The main process asks Firebase Authentication to create Google's browser
   authorization URL, including an exact loopback callback and a random local
   context value. Firebase also returns a one-time session id.
2. The browser returns to the loopback callback. The main process gives that
   response and one-time session id directly to Firebase Authentication.
   Firebase validates Google's response and returns a short-lived Firebase ID
   token and refresh token. Kaisola also verifies the returned context.
3. The app sends the Firebase ID token to the `session` Cloud Function. The
   Admin SDK verifies its signature, issuer, audience, expiry, disabled-user
   state, and revocation before writing the user's server-owned profile.

Only the refresh token is durable, encrypted with Electron `safeStorage` (the
OS keychain) in the main process. No Firebase token reaches React, localStorage,
the project workspace, logs, or Firestore client code. The untrusted renderer
can only ask main for a redacted status/profile.

Firestore remains deny-all for clients. `functions/index.js` uses the Admin SDK
and therefore does not depend on client Security Rules.

## Public desktop config

Copy `electron/firebase-config.example.json` to
`electron/firebase-config.json` and fill in:

- `projectId`: `kaisola-a9ab7`
- `apiKey`: a dedicated Firebase client key restricted to the APIs below
- `serverUrl`: the deployed `session` function URL

The same values can be supplied at build/runtime through
`KAISOLA_FIREBASE_PROJECT_ID`, `KAISOLA_FIREBASE_API_KEY`, and
`KAISOLA_AUTH_SERVER_URL`.

### API-key safety

A desktop application's Firebase key is visible to anyone who downloads the
app. It must therefore authorize only the Firebase APIs that the sign-in flow
uses:

- Identity Toolkit API (`identitytoolkit.googleapis.com`)
- Token Service API (`securetoken.googleapis.com`)

Never allow the Generative Language API (Gemini), Vertex AI, or another billed
non-Firebase API on this key. Use a separate server-side credential for those
services. If a client key ever allowed one of them, remove that API restriction
and rotate the key before publishing another build.

`electron/firebase-config.json` is generated and gitignored. For release
builds, add the rotated Firebase-only key as the GitHub Actions repository
secret `KAISOLA_FIREBASE_API_KEY`. The workflow writes the gitignored Firebase
config immediately before packaging. This keeps the value out of source
history, but it does not make it secret inside the distributed desktop app—the
Firebase API restrictions are the security boundary.

Kaisola does not ship a Google OAuth client secret. The desktop app delegates
the Google code exchange to Firebase through `accounts:createAuthUri` and
`accounts:signInWithIdp`, using the Google provider already configured in the
Firebase project. This avoids distributing a confidential Web client secret or
depending on a Desktop client whose token endpoint requires one.

Never commit the OAuth JSON, a service-account JSON, personal access token, or
refresh token. Cloud Functions receives its service identity from Google at
runtime.

## Deploy

From the repository root, after `firebase login`:

```sh
firebase deploy --only functions:session,firestore:rules
```

The function creates/updates `users/{firebaseUid}` with name, email, provider,
`createdAt`, and `lastSeenAt`. It returns only the verified uid/name/email.

## Firebase / Google Console checklist

1. Authentication → Sign-in providers → Google: enabled (already shown in the
   supplied screenshot).
2. Project settings → General → Your apps: register a Web app if none exists,
   then copy its Web API Key into the desktop config.
3. Google Auth Platform → Clients → open the Web application client used by
   Firebase and add this exact Authorized redirect URI:
   `http://localhost:42813/oauth/callback`. Google requires an exact redirect
   match; Kaisola reserves that stable loopback port for sign-in.
4. Google Auth Platform → Branding: change the public-facing name from
   `project-60313772450` to `Kaisola`; keep the support email selected.
5. If the consent screen is in Testing, add intended testers. Publish to
   Production before offering sign-in broadly.
6. Cloud Functions deployment may require the Blaze plan. The Firebase CLI will
   say so before deployment.

Email/password and Phone are currently not exposed by Kaisola. Disable them
until their UI, recovery, abuse controls, and (for Phone) billing safeguards are
implemented. Google is the only provider this release consumes.
