# Brain Clipper for Chrome

A Manifest V3 extension that sends the current page directly to the existing
Brain capture gateway. It provides:

- a toolbar popup with an optional note and explicit **Design reference** type;
- right-click **Save page to Brain**;
- right-click capture for selected text and links;
- right-click **Save to Brain as design** for visual references and tweets. The
  clipper sends visible page context and prefers the underlying image when it
  can read it, with a visible-tab screenshot as the offline-safe fallback.

For X design posts, the gateway immediately retries the status and prefers the
original `pbs.twimg.com` photo over the surrounding X page. The save
confirmation says when a local visual and context were retained; missing
evidence is queued with a precise retry marker.

## Install

1. Open `chrome://extensions`, enable **Developer mode**, and choose **Load
   unpacked**.
2. Select this `apps/brain-clipper/` directory.
3. Open the extension's **Details → Extension options**.
4. Enter the gateway URL. Run `scripts/brain clipper-token`, then use **Paste**
   to insert the token without printing it in Terminal.
5. Choose **Test and save connection**.

After changing the unpacked extension files, use **Reload** on
`chrome://extensions` so the richer design capture path becomes active.

The token stays in `chrome.storage.local`; it is not committed, placed in the
extension bundle, or synced through the Google account. Anyone with the token
can add inbox items, but cannot read or modify the rest of the repository.
