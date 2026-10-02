# Using your organization's own Google client with Cove

Cove's shared Google sign-in is in private beta, so only addresses on its tester list can sign in. A **Google Workspace** organization can avoid that by registering its own Google client as **Internal**. Then:

- everyone in the organization can sign in;
- there is no tester list, no 100-user limit, no weekly sign-in expiry, and no Google verification;
- the organization's admin owns the client and can revoke it at any time.

This works only for Google Workspace domains. Personal @gmail.com accounts can't use an Internal client.

## Admin setup (about 15 minutes)

1. Open [Google Cloud Console](https://console.cloud.google.com/) with an admin account of the organization and create a project (for example "Cove").
2. **APIs & Services → Library:** enable **Gmail API**, **Google Calendar API** and **Google Tasks API**.
3. **Google Auth Platform → Branding:** set the app name to "Cove" and add a support email.
4. **Audience:** choose **Internal**.
5. **Data Access → Add or remove scopes:** add
   - `https://www.googleapis.com/auth/gmail.modify`
   - `https://www.googleapis.com/auth/calendar.events`
   - `https://www.googleapis.com/auth/tasks`
   - `openid` and `email`, only if you'll use Cove's optional cloud sync.
6. **Clients → Create client:** choose **Application type: Desktop app**. Copy the **Client ID** and **Client secret** and share them privately with your team.

## In Cove

1. Open the account menu (your avatar in the sidebar).
2. Choose **Add work account (own Google client)…**.
3. Paste the Client ID and secret.
4. Choose **Continue in browser**, and sign in with your organization account.

## Notes

- The client is used only for that account. Other accounts keep Cove's shared client.
- Reconnecting that account later (for example to add Calendar or Tasks) reuses the same client automatically.
- Cove stores the client with the account's sign-in in the macOS Keychain and never displays the secret.
- A Desktop app's "secret" is not truly confidential, because Google treats installed apps as public clients. Revoke it from the project if needed.
- If a Workspace admin blocks third-party apps, also allow this client in **Admin console → Security → API controls**.
