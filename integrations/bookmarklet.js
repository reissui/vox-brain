/*
 * Brain capture bookmarklet — readable source.
 *
 * Captures the current page (URL + any selected text) into the Brain inbox by
 * POSTing to the capture gateway:
 *
 *   POST <GATEWAY_URL>/capture
 *   Authorization: Bearer <CAPTURE_TOKEN>
 *   {"url": "<location.href>", "note": "<selected text, may be empty>", "source": "bookmarklet"}
 *
 * Install: see integrations/capture-everywhere.md, section "Gateway clients"
 * — substitute the two placeholders below, minify, prefix with `javascript:`,
 * and save as a bookmark. Never commit real values to this file.
 */
(function () {
  "use strict";

  var GATEWAY_URL = "__GATEWAY_URL__"; // e.g. https://brain-gateway.<you>.workers.dev
  var TOKEN = "__TOKEN__"; // your CAPTURE_TOKEN — placeholder, substitute on install

  // Success/failure feedback: a small temporary DOM toast, never alert().
  function toast(message, ok) {
    var el = document.createElement("div");
    el.textContent = message;
    el.style.cssText =
      "position:fixed;top:16px;right:16px;z-index:2147483647;" +
      "padding:10px 14px;border-radius:8px;" +
      "font:13px/1.4 -apple-system,system-ui,sans-serif;color:#fff;" +
      "box-shadow:0 2px 10px rgba(0,0,0,.3);" +
      "background:" + (ok ? "#1a7f37" : "#b42318");
    document.body.appendChild(el);
    setTimeout(function () {
      if (el.parentNode) {
        el.parentNode.removeChild(el);
      }
    }, 2500);
  }

  var selection = "";
  if (window.getSelection) {
    selection = String(window.getSelection()).trim();
  }

  fetch(GATEWAY_URL.replace(/\/+$/, "") + "/capture", {
    method: "POST",
    headers: {
      "Authorization": "Bearer " + TOKEN,
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      url: location.href,
      note: selection,
      source: "bookmarklet"
    })
  }).then(function (res) {
    if (res.ok) {
      toast("Saved to Brain", true);
    } else {
      toast("Brain capture failed (HTTP " + res.status + ")", false);
    }
  }).catch(function () {
    toast("Brain capture failed (network)", false);
  });
})();
