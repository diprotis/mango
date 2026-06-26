# Enabling Google, Apple & Phone sign-in (production checklist)

Exact, copy-pasteable steps to take Mango from "email login works" to "Google +
Sign in with Apple + phone all work" against a real Cognito user pool.

Backend wiring already exists (`backend/mango_backend/auth_stack.py`); every
provider is **off by default** and turned on per stage via
`backend/config/<stage>.json`. You never edit Swift or Python for this — you flip
config flags, set one secret per provider in the console/CLI, and redeploy.

Conventions below use **`<stage>` = `dev`** and **`PROFILE` = `diprotis-dev`**.
Substitute `beta`/`prod` as needed.

---

## 0. Two redirect URIs you'll reuse everywhere

After your first deploy you'll have a Hosted-UI domain. Everything plugs into one
of these two URIs:

| Used by | URI |
|---|---|
| **Google / Apple** (the IdP "redirect/return URL") | `https://<DOMAIN>/oauth2/idpresponse` |
| **The iOS app** (Cognito app-client callback) | `mango://callback` |

`<DOMAIN>` looks like `mango-dev-123456789012.auth.us-east-1.amazoncognito.com`
and is printed as the `UserPoolDomain` stack output (see step 1).

---

## 1. Deploy once and capture your values

Prerequisites (one-time):

1. AWS credentials for the profile: `aws sso login --profile diprotis-dev`
   (or configured access keys).
2. CDK bootstrap (once per account/region): `make backend-bootstrap`
3. **Amazon Bedrock model access** — in the Bedrock console → *Model access*,
   enable the model id set in `backend/config/dev.json` (`bedrockModelId`) in the
   pool's region (`us-east-1`). Without this the roadmap call returns 500.

Deploy + run the live end-to-end check:

```bash
make backend-deploy-verify STAGE=dev PROFILE=diprotis-dev
```

This prints (and the smoke test uses) the values you need. To re-read them later:

```bash
aws cloudformation describe-stacks --profile diprotis-dev \
  --query "Stacks[].Outputs[?OutputKey=='UserPoolId'||OutputKey=='UserPoolClientId'||OutputKey=='UserPoolDomain'||OutputKey=='ApiUrl'].[OutputKey,OutputValue]" \
  --output text
```

Note the four values: **ApiUrl, UserPoolId, UserPoolClientId, UserPoolDomain**.

> At this point **email sign-in already works** through the Hosted UI — that's
> enough to prove the "new user → catalog → create roadmap" flow. Google/Apple/
> phone below are additive.

---

## 2. Point the iOS app at your pool (required for any Hosted-UI login)

Edit `ios/Mango/Resources/AppConfig.plist` and fill the four Cognito keys (strip
`https://` from the domain output — the app wants the bare host):

```xml
<key>CognitoDomain</key>          <string>mango-dev-123456789012.auth.us-east-1.amazoncognito.com</string>
<key>CognitoClientId</key>        <string>PASTE UserPoolClientId</string>
<key>CognitoRegion</key>          <string>us-east-1</string>
<key>CognitoRedirectScheme</key>  <string>mango</string>
```

Also set `ProdAPIURL` / `BetaAPIURL` to your `ApiUrl` so the app talks to the
deployed backend. `mango://callback` is handled by `ASWebAuthenticationSession`
via `CognitoRedirectScheme` — no Info.plist URL-type registration is required.
Rebuild the app; tap **Continue** on the sign-in screen and you should land on the
Cognito Hosted UI.

---

## 3. Enable Google

**A. Google Cloud Console** (<https://console.cloud.google.com>):

1. Create/select a project → *APIs & Services → OAuth consent screen* → configure
   (External; add your email as a test user while unverified).
2. *APIs & Services → Credentials → Create credentials → OAuth client ID* →
   **Application type: Web application**.
3. Under **Authorized redirect URIs** add exactly:
   `https://<DOMAIN>/oauth2/idpresponse`
4. Create → copy the **Client ID** and **Client secret**.

**B. Backend** — set config + the secret, then deploy:

```bash
# backend/config/dev.json
"enableGoogle": true,
"googleClientId": "1234567890-abc.apps.googleusercontent.com",

# deploy so the stack creates the IdP + the placeholder secret
make backend-deploy-personal STAGE=dev PROFILE=diprotis-dev

# put the real Google client SECRET into the secret the stack just created
aws secretsmanager put-secret-value --profile diprotis-dev \
  --secret-id mango/dev/google-oauth \
  --secret-string 'PASTE-GOOGLE-CLIENT-SECRET'

# redeploy so the Google IdP picks up the secret value
make backend-deploy-personal STAGE=dev PROFILE=diprotis-dev
```

The app's **Continue with Google** button (and the Hosted-UI Google option) now work.

---

## 4. Enable Sign in with Apple

**A. Apple Developer** (<https://developer.apple.com/account>, needs a paid
membership):

1. *Certificates, IDs & Profiles → Identifiers → +* → **App ID** for the app
   (note the **Team ID**, top-right of the account).
2. *Identifiers → +* → **Services ID** (e.g. `com.yourorg.mango.signin`) → enable
   **Sign In with Apple** → Configure:
   - **Domains**: `<DOMAIN>` (the bare host)
   - **Return URLs**: `https://<DOMAIN>/oauth2/idpresponse`
   - This Services ID string is your **`appleServicesId`**.
3. *Keys → +* → enable **Sign in with Apple** → register → **download the `.p8`**
   (one-time) → note the **Key ID** (`appleKeyId`).

**B. Backend** — set config + the `.p8` secret, then deploy:

```bash
# backend/config/dev.json
"enableApple": true,
"appleServicesId": "com.yourorg.mango.signin",
"appleTeamId": "ABCDE12345",
"appleKeyId": "XYZ987WUV6",

make backend-deploy-personal STAGE=dev PROFILE=diprotis-dev

# store the downloaded private key (entire .p8 contents) as the secret value
aws secretsmanager put-secret-value --profile diprotis-dev \
  --secret-id mango/dev/apple-signin \
  --secret-string file://AuthKey_XYZ987WUV6.p8

make backend-deploy-personal STAGE=dev PROFILE=diprotis-dev
```

The app's **Sign in with Apple** button + the Hosted-UI Apple option now work.
(This is the web-federated Apple flow via Hosted UI; a fully native
`ASAuthorizationAppleIDButton` is a later enhancement.)

---

## 5. Enable phone (SMS) sign-in

Cognito sends the verification SMS via Amazon SNS; new accounts start in the SNS
**SMS sandbox** (only verified numbers receive messages).

**A. Backend** — flip the flag and deploy (the stack provisions the Cognito→SNS
IAM role automatically):

```bash
# backend/config/dev.json
"enablePhone": true,

make backend-deploy-personal STAGE=dev PROFILE=diprotis-dev
```

**B. AWS console (SNS)** — *Amazon SNS → Text messaging (SMS)*:

1. **Sandbox (dev/test):** add + verify each tester's phone number under
   *Sandbox destination phone numbers*. Only verified numbers get codes.
2. **Production (beta/prod):** request **production access** (moves you out of the
   sandbox) and set a **monthly SMS spending limit**. SMS costs real money per
   message — set the limit deliberately.

Phone shows up as an option in the Hosted UI (the app's **Continue** button).

---

## 6. Verify everything

```bash
# Re-run the live end-to-end gate (real Cognito + real Bedrock)
make backend-deploy-verify STAGE=dev PROFILE=diprotis-dev
```

Then in the app: **Continue** (or the provider buttons) → sign in → **Catalog**
tab → pick *Meditations* → **Create roadmap**. You should get a generated roadmap
from the backend.

---

## 7. Quick reference

**Config flags** (`backend/config/<stage>.json`):

| Key | Provider |
|---|---|
| `enableGoogle` + `googleClientId` | Google |
| `enableApple` + `appleServicesId` / `appleTeamId` / `appleKeyId` | Apple |
| `enablePhone` | Phone/SMS |
| `cognitoDomainPrefix` | optional vanity Hosted-UI prefix (must be globally unique) |

**Secrets** (set out-of-band with `aws secretsmanager put-secret-value`):

| Secret id | Value |
|---|---|
| `mango/<stage>/google-oauth` | Google OAuth **client secret** |
| `mango/<stage>/apple-signin` | Apple **`.p8`** private-key contents |

**iOS** (`ios/Mango/Resources/AppConfig.plist`): `CognitoDomain`,
`CognitoClientId`, `CognitoRegion`, `CognitoRedirectScheme=mango`.

---

## 8. Troubleshooting

- **Google/Apple login → "invalid client secret":** you set the secret *after* the
  IdP was created and the redeploy didn't refresh it. Force it once:
  `aws cognito-idp update-identity-provider --user-pool-id <UserPoolId> --provider-name Google --profile diprotis-dev` (re-supplying `client_secret` in `--provider-details`), or re-run the deploy after a trivial config touch.
- **`redirect_mismatch`:** the IdP's return URL or the app-client callback doesn't
  exactly match `https://<DOMAIN>/oauth2/idpresponse` / `mango://callback`.
- **Phone code never arrives:** number isn't verified in the SNS sandbox, or you're
  past your SMS spend limit.
- **Roadmap returns 500:** Bedrock model access not enabled for `bedrockModelId`
  in the pool's region.
- **`make backend-deploy-verify` says Cognito outputs missing:** the deploy didn't
  finish or you're reading a different region/profile than you deployed to.

See also `docs/specs/0003-authentication.md` and `docs/DEPLOY.md`.
