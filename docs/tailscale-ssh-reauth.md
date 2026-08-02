# Tailscale SSH re-auth loop (deploys break ~once a day)

Diagnosed 2026-07-29. Tailnet `h2ds.ai`. Affects anything reaching `black-betty` over
`ssh://nas` (host `nas` → `black-betty`, user `root`) — cron, agent sessions, and
cabana-web's `deploy-prod.sh` / `deploy-sandbox.sh`.

## Symptom

A non-interactive SSH or `docker --context nas` call prints:

```
# Tailscale SSH requires an additional check.
# To authenticate, visit: https://login.tailscale.com/a/...
```

and then blocks. Visiting the URL in a browser clears it for roughly a day, then it
recurs. Automation (deploy scripts, cron, agent sessions) cannot self-recover,
because clearing it needs a human with a browser.

## Root cause

The tailnet policy file's `ssh` section grants `"action": "check"` for the rule that
covers Andy's own devices. `check` mode requires periodic interactive
re-authentication, on a `checkPeriod` that **defaults to 12 hours**. That 12-hour
window is the "roughly once a day" cadence.

This is not device key expiry. Key expiry is already disabled on the relevant nodes
(`black-betty` reports `KeyExpiry: null`) and the MacBook's key runs to 2027-01-15.

### Evidence

Tailscale compiles the policy file into a per-node SSH policy and ships it in the
node's netmap. Read the authoritative, already-compiled rules from the *server* node
— no API token needed:

```bash
ssh nas 'tailscale debug netmap' | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["SSHPolicy"], indent=2))'
```

On 2026-07-29 that returned two rules. The standing rule is the check rule:

```json
{
  "action": {
    "holdAndDelegate": "https://unused/machine/ssh/action/$SRC_NODE_ID/to/$DST_NODE_ID?local_user=$LOCAL_USER"
  },
  "principals": [
    { "nodeIP": "100.127.182.121" },
    { "nodeIP": "100.66.184.114" },
    { "nodeIP": "100.69.57.8" },
    { "nodeIP": "100.82.228.119" },
    { "nodeIP": "100.86.239.127" }
  ],
  "sshUsers": { "*": "=", "0": "", "root": "root" }
}
```

`holdAndDelegate` **is** how `"action": "check"` compiles — the node holds the
session and delegates the decision to that check endpoint, which is what renders the
browser prompt.

The other rule is the temporary grant minted by the last successful browser check:

```json
{
  "action": { "accept": true, ... },
  "principals": [ { "nodeIP": "100.66.184.114" } ],
  "ruleExpires": "2026-07-30T09:48:49Z",
  "sshUsers": { "*": "=", "0": "", "root": "root" }
}
```

Note it is scoped to a single node IP (the MacBook, `100.66.184.114`) and carries
`ruleExpires` exactly 12 hours after it was issued — the documented default
`checkPeriod`. Rules are evaluated in order, so while that grant is live SSH works;
when it expires, evaluation falls through to the check rule and the prompt returns.

The `principals` list is every one of Andy's devices and none of Hannah's, and
`sshUsers` is `autogroup:nonroot` plus an explicit `root`. That is the stock rule
Tailscale ships in new tailnets:

```json
{
  "action": "check",
  "src":    ["autogroup:member"],
  "dst":    ["autogroup:self"],
  "users":  ["autogroup:nonroot", "root"]
}
```

## Fix (requires the Tailscale admin console — Andy's clicks)

`checkPeriod` maxes out at 168h (one week) and has no "never" value, so raising it
only converts a daily interruption into a weekly one. To remove the recurring browser
prompt, the rule covering Andy's own devices must be `accept`, not `check`.

Admin console → **Access Controls** → edit the policy file. Add an `accept` rule
scoped to Andy specifically, *above* the existing `check` rule (first match wins), and
leave the `check` rule in place for everyone else:

```diff
   "ssh": [
+    // Andy's own devices, non-interactively. `check` here forced a browser
+    // re-auth every 12h, which broke docker-over-SSH deploys and cron.
+    {
+      "action": "accept",
+      "src":    ["andy@h2ds.ai"],
+      "dst":    ["autogroup:self"],
+      "users":  ["autogroup:nonroot", "root"]
+    },
     {
       "action": "check",
       "src":    ["autogroup:member"],
       "dst":    ["autogroup:self"],
       "users":  ["autogroup:nonroot", "root"]
     }
   ]
```

Why this is the narrow version:

- `dst: autogroup:self` already means "the source user's own untagged devices", so
  this grants Andy access to Andy's machines and nothing else. `black-betty` is
  untagged and owned by `andy@h2ds.ai`, so it is covered.
- Other tailnet members (Hannah) keep `check`, and even under `accept` they would
  only ever reach *their own* devices — never the NAS.
- Nothing is opened to `autogroup:shared`, tagged infrastructure, or the internet.

Do not simply flip the existing rule's `check` to `accept` unless you intend that for
every member. The extra rule is one more line and strictly narrower.

Optional posture improvement, separate change: `~/.ssh/config` uses `User root` for
host `nas` because the docker socket needs it. Dropping `root` from the `users` list
and switching to a non-root user in a `docker` group would let the rule be
`["autogroup:nonroot"]` only. Out of scope here.

### Verify after the console change

```bash
ssh -o BatchMode=yes -o ControlPath=none -o ConnectTimeout=15 nas true && echo OK
docker --context nas ps
ssh nas 'tailscale debug netmap' | grep -c holdAndDelegate   # expect the rule gone for this node
```

`ControlPath=none` matters: `~/.ssh/config` sets `ControlPersist 600` for `nas`, so a
warm multiplexed connection keeps working after the grant lapses and will mask the
problem. Always test a fresh handshake.

## Unrelated hygiene found while diagnosing

The MacBook has a Homebrew `tailscale` CLI at 1.92.5 while the running daemon is
1.98.9, so every CLI call prints a version-mismatch warning. Either
`brew uninstall tailscale` and use the app's binary
(`/Applications/Tailscale.app/Contents/MacOS/Tailscale`), or `brew upgrade tailscale`.
Not a cause of the re-auth loop.

## Deploy-script hardening (already landed, independent of the console fix)

`scripts/nas-preflight.sh` now:

1. Probes a **fresh** (non-multiplexed) Tailscale SSH handshake before anything else,
   bounded to 20s, and on a pending check prints the extracted
   `https://login.tailscale.com/...` URL and exits 1 — instead of hanging until a
   timeout with no explanation. A second stage separately probes the docker daemon, so
   "NAS asleep" and "docker wedged" get different messages.
2. Adds `deploy_baseline` / `verify_deploy_replaced`, which fingerprint the running
   container before the build and refuse to print a success message unless the
   container was actually recreated or restarted, and is younger than
   `DEPLOY_MAX_CONTAINER_AGE_S` (default 900s).

(2) closes a worse bug than the auth loop: `deploy-sandbox.sh` once reported success
while the running container was still 22 hours old. Both pre-existing post-deploy
checks — `docker compose ps | grep Up` and the loopback `curl` — pass happily for a
stale container that no deploy step ever touched.

Escape hatch for a deliberate no-op deploy (unchanged source ⇒ identical image ⇒
compose declines to recreate):

```bash
ALLOW_UNCHANGED_DEPLOY=1 ./deploy-sandbox.sh
```
