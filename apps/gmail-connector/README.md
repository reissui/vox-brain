# Brain Gmail connector

Live, read-only Gmail retrieval for Brain questions. It does **not** mirror the
mailbox into the vault, require a Gmail label, or commit email content to Git.
`brain ask` and the private Telegram assistant can search Gmail when the user's
question calls for it, inspect a matching thread, and synthesize an answer.

## Connect in Brain.app

In Google Cloud, enable the Gmail API and create a **Desktop app** OAuth client
with this scope:

```text
https://www.googleapis.com/auth/gmail.readonly
```

Open **Brain → Settings → Google Gmail**, choose **Connect**, and select the
downloaded JSON. Brain validates it, copies it through private local storage,
and opens Google in the default browser to complete consent. The temporary
selected-file copy is removed when authorization finishes.

The equivalent terminal commands are:

```sh
brain gmail connect ~/Downloads/client_secret_….json
brain gmail status --check-api
```

The first command opens Google in a browser for consent. The downloaded client
configuration and resulting refresh token are copied to
`~/Library/Application Support/Brain/` with owner-only permissions; neither is
written to the repository. Delete the copy in Downloads after connection.

Authorization is local to the Mac where it is completed. Connect in Brain.app
for questions run on this Mac. If the Telegram bot answers on the remote runner,
also run the terminal connection there so that machine has its own private
authorization.

If the OAuth app remains in Google's **Testing** publishing status, test-user
authorization expires after seven days. Reconnect when `brain doctor` reports
that Gmail authorization has expired:

```sh
brain gmail reconnect
```

Brain.app exposes the same **Reconnect** action in Settings. **Disconnect**
revokes the Google grant when possible and always removes Brain's local client
and token files; it never changes mailbox content.

Changing the OAuth publishing status to Production does not publish the Brain
or list this personal app publicly; it only removes the testing lifecycle. The
app may remain unverified for personal use.

## Use

Ask naturally:

```sh
brain ask "What price did Alex quote me for the redesign?"
brain ask "Find the latest delivery date mentioned in my Acme email thread"
```

The connector exposes only two read operations to the answering agent:

- `gmail_search` — Gmail search syntax, with message text and headers;
- `gmail_get_thread` — the complete thread for a returned result.

Email is untrusted source material, not instructions. Search results are passed
transiently to the Codex answering run and are not saved unless the owner explicitly
asks to capture the resulting information.
