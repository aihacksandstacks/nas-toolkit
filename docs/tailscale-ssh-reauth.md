# Tailscale SSH re-auth loop (deploys break ~once a day)

> **Status: fixed 2026-10-11.** See [Fix](#fix-applied-2026-10-11-in-the-tailscale-admin-console).

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

## Fix (applied 2026-10-11 in the Tailscale admin console)

**Rule order does not matter.** Tailscale evaluates SSH rules "using the most
restrictive policies first": when a connection matches both an `accept` and a `check`
rule, `check` wins regardless of where each sits in the policy file
([ACL syntax docs](https://tailscale.com/kb/1337/acl-syntax)). An earlier version of
this doc said to add an `accept` rule *above* the `check` rule. That was tried on
2026-10-10 and changed nothing: the node still compiled `check` first and the prompt
returned 12h later.

`checkPeriod` maxes out at 168h with no "never" value, so it cannot remove the prompt
either. The only fix is for **no `check` rule to match Andy's devices**. The `ssh`
section now reads:

```json
"ssh": [
  {
    "action": "accept",
    "src":    ["andy@h2ds.ai"],
    "dst":    ["autogroup:self"],
    "users":  ["autogroup:nonroot", "root"]
  },
  {
    "action": "check",
    "src":    ["hannahhepler@gmail.com"],
    "dst":    ["autogroup:self"],
    "users":  ["autogroup:nonroot", "root"]
  }
],
```

- The stock rule's `src: ["autogroup:member"]` included Andy, which is what kept the
  `check` matching. It is narrowed to Hannah's login, so Andy matches only `accept`.
- `dst: autogroup:self` means "the source user's own untagged devices". Andy reaches
  Andy's machines (including `black-betty`, untagged and owned by `andy@h2ds.ai`);
  Hannah reaches only hers, with the periodic check.
- A member added later gets no Tailscale SSH until a rule names them.
- Hannah's rule does **not** let anyone SSH from her Mac into Andy's devices. To work
  on the NAS from her machine, switch that Mac's Tailscale to Andy's account
  temporarily (menu bar, account switcher), or SSH from one of Andy's own devices.

Optional posture improvement, separate change: `~/.ssh/config` uses `User root` for
host `nas` because the docker socket needs it. Dropping `root` from the `users` list
and switching to a non-root user in a `docker` group would let the rule be
`["autogroup:nonroot"]` only.

### Verify after a policy change

Read the compiled rules from the server node. After the fix, `black-betty` holds a
single standing `accept` rule covering Andy's node IPs, with no `check`
(`holdAndDelegate`) rule and no expiring grant:

```bash
ssh -o ControlPath=none nas 'tailscale debug netmap' | python3 -c '
import json,sys
for r in json.load(sys.stdin)["SSHPolicy"]["rules"]:
    a=r["action"]; print("accept" if a.get("accept") else "check" if a.get("holdAndDelegate") else a,
                         len(r.get("principals",[])), r.get("ruleExpires","(standing)"))'
ssh -o BatchMode=yes -o ControlPath=none -o ConnectTimeout=15 nas true && echo OK
docker --context nas ps
```

Verified 2026-10-11: one rule, `accept`, 12 principals, standing; fresh handshake OK.

`ControlPath=none` matters: `~/.ssh/config` sets `ControlPersist 600` for `nas`, so a
warm multiplexed connection keeps working after a grant lapses and will mask the
problem. Always test a fresh handshake.

## Unrelated hygiene found while diagnosing

The MacBook had a Homebrew `tailscale` CLI at 1.92.5 while the running daemon was
1.98.9, so every CLI call printed a version-mismatch warning. Not a cause of the
re-auth loop. Resolved 2026-10-10: the Homebrew CLI is gone and the MacBook runs the
Standalone Tailscale app, whose installer provides `/usr/local/bin/tailscale`.

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
