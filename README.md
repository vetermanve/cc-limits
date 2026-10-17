# cc-limits

A terminal gauge for your Claude Code usage limits: the 5-hour window and the
weekly window, with a reset countdown, how far your burn deviates from an even
pace, and a projection of when you will run out.

The numbers are the real ones. `cc-limits` reads the same endpoint Claude Code
itself uses for `/usage`, so it is not an estimate reconstructed from local
token counts.

Russian README: [README.ru.md](README.ru.md)

> Note: the tool's own output is in Russian. Everything else (code, comments in
> this file, flags) is language-neutral. See [Limitations](#limitations).

## What it looks like

One-shot:

```
Лимиты Claude Code  19:05:16

 5ч    [########..........................]  24.0%  сброс 1ч 54м  откл -61%  хватит до сброса (8.5%/ч)
 7д    [######............................]  19.0%  сброс 1д 12ч 54м  откл -76%  хватит до сброса (1.0%/ч)
 Fable [..................................]   0.0% (квота 50% недели)

 неделя: Claude Code 100%
```

In the Claude Code status line, refreshed every turn:

```
> my-project  git:(main)  5ч 24% -61% 1ч 54м | 7д 19% -76% 1д 12ч 54м | 19:05
```

Reading a row:

| Field | Meaning |
| --- | --- |
| `24.0%` | utilization of the usable budget, which is the whole window unless you set a [reserve](#shared-account-reserving-part-of-a-window). Colored by risk, see below |
| `сброс 1ч 54м` | time until the window resets |
| `откл -61%` | deviation from an even burn of the budget: `0%` is exactly on pace, `-61%` means you are 61% slower than even (you have slack), `+20%` means 20% faster. Green at or below zero, yellow above |
| `хватит до сброса (8.5%/ч)` | measured burn rate and whether it lasts until the reset. Turns into a red `КОНЕЦ через 1ч 30м` when the projection says you run out first |

The utilization figure is colored by risk, not by its own level: red once the
budget is spent (at or above 100%) or the projection says you run out before
the reset, yellow while you burn faster than an even pace, green otherwise. A
raw percentage says nothing about risk on its own, which is why an absolute
threshold would lie: 60% ten minutes before the reset is slack, and painting it
yellow would contradict the deviation sitting right next to it.

## Shared account: reserving part of a window

If the account is shared and you have to leave part of a window for someone
else, declare that share as a reserve. Everything then counts against the
budget that is actually yours: with a 20% reserve on the 5-hour window, burning
80% of the window reads as `100.0%`, and anything beyond that reads above 100.

`$CLAUDE_CONFIG_DIR/cc-limits.json` (default `~/.claude/cc-limits.json`):

```json
{
  "reserve": {
    "five_hour": 20,
    "seven_day": 0
  }
}
```

Or per invocation: `CC_LIMITS_RESERVE_5H=20`, `CC_LIMITS_RESERVE_7D=0`. The
environment wins over the file. Default is no reserve, in which case the
numbers are the raw window percentages.

```
Лимиты Claude Code  19:25:20
 проценты от бюджета, 5ч: 100% = 80% окна (резерв 20%)

 5ч    [#############.....................]  37.5%  (30% окна)  сброс 1ч 34м  откл -45%  хватит до сброса (14.0%/ч)
```

The scaling is never silent: the header states the budget, the row keeps the
raw window figure in parentheses, and the status line marks the window with an
asterisk (`5ч* 38%`). The projection and the deviation are scaled too, so
`КОНЕЦ через ...` means running out of your share, not of the window.

The reserve only affects presentation. `--json` stays raw, and the sample
history is stored raw as well, so changing the reserve does not corrupt past
measurements. A malformed config is a hard error rather than a silent fallback
to zero, because quietly counting against the wrong budget is the one failure
this feature exists to prevent.

## Multiple accounts

There can be more than one token: your personal subscription in the Keychain
and, say, a shared long-lived token for a fleet of machines minted with
`claude setup-token`. Their limit windows are separate, so accounts are
declared in the config and each one gets its own cache, history and throttle
state: a mixed history would turn the burn rate and the projection into
nonsense, and a `429` on one token would lock out requests on the other.

```json
{
  "accounts": [
    {"name": "личный", "source": "keychain"},
    {"name": "флот", "source": "file", "path": "~/.secrets/fleet-token",
     "reserve": {"five_hour": 50}}
  ]
}
```

Where the token comes from is the `source` field:

| source | token |
| --- | --- |
| `auto` | the Claude Code order: `$CLAUDE_CODE_OAUTH_TOKEN`, Keychain, `.credentials.json` |
| `keychain` | macOS Keychain, service `Claude Code-credentials` |
| `credentials` | `$CLAUDE_CONFIG_DIR/.credentials.json` |
| `env` | the environment variable named in `var` |
| `file` | the file at `path`: a bare token or a session JSON |
| `command` | stdout of `command`, e.g. from a secret manager |
| `token` | the `token` value inline in the config |

A per-account `reserve` overrides the global
[reserve](#shared-account-reserving-part-of-a-window) for that account. Without
an `accounts` section nothing changes: one account, the previous cache file
names, no labels in the output.

The one-shot output prints a block per account, with the current window's
account marked:

```
Лимиты Claude Code  15:46:14

 личный  (данным 14с)
 5ч    [##############....................]   40.0%  сброс 1ч 59м  откл -33%  хватит до сброса (9.2%/ч)
 7д    [###...............................]   10.0%  сброс 3д 23ч 59м  откл -77%  прогноз: мало замеров (2)

 флот  (это окно)
 проценты от бюджета, 5ч: 100% = 50% окна (резерв 50%)
 5ч    [####################..............]   60.0%  (30% окна)  сброс 1ч 59м  откл  +0%  хватит до сброса (9.0%/ч)
 7д    [#####.............................]   15.0%  сброс 3д 23ч 59м  откл -65%  прогноз: мало замеров (2)
```

### The current window's account

In the status line the name of the account this very window runs on comes last,
behind the same vertical bar:

```
5ч 24% -61% 1ч 54м | 7д 19% -76% 1д 12ч 54м | 19:05 | флот
```

The status line cannot see `$CLAUDE_CODE_OAUTH_TOKEN`: Claude Code strips it
from the environment of child processes. So the window's token is read from the
environment of the `claude` process itself, via `$CLAUDE_PID` and otherwise by
walking the parent chain (`/proc/<pid>/environ` on Linux, `ps eww` on macOS).
The easy trap: `ps` shows the environment as of `exec`, so a variable exported
by `.zshrc` is invisible on the shell itself but visible on the `claude` it
launched.

When the variable is nowhere to be found the window runs on the Keychain
session, and the account with `source` `keychain`, `credentials` or `auto` gets
the label. When the window's token is not declared in the config, a warning
takes the place of the name:

```
... | 19:05 | аккаунт ? токен этого окна в конфиге не описан
```

That is not cosmetic: the numbers on such a line belong to a different account,
and this window's burn shows up nowhere. `cc-limits --accounts` prints which
accounts are declared and which one the current window uses.

Not every token works for limits. A token from `claude setup-token` - the
long-lived kind you hand out to machines - comes **without the `user:profile`
scope**, which this endpoint requires. Worse, the server answers such a token
with `429` rather than `403`, indistinguishable from a spent request window. So
on the first `429` `cc-limits` asks `/api/oauth/profile` once and, when the
scope is missing, says so outright:

```
... | 19:05 | флот: токен без scope, лимиты недоступны
```

The verdict is remembered for a day, keyed by the token fingerprint, and after
that no request is made at all - the answer is foregone. A re-minted token gets
re-checked. There is no way to get limits for a token without that scope: it
needs a `/login` session.

Token sources are probed cheapest first and only until one matches, and the
match is remembered for an hour in `cache/cc-limits-window.json` keyed by a
token fingerprint (sha256, first 16 chars; the token itself is not stored).
Otherwise a `source: command` account would invoke your secret manager on every
status line refresh.

## Install

Requires Python 3.9+ (no third-party packages) and a Claude subscription
logged into Claude Code.

```sh
git clone https://github.com/vetermanve/cc-limits.git
cd cc-limits
./install.sh
```

`install.sh` copies the script to `~/.local/bin/cc-limits` and prints the
snippet for the status line. Or do it by hand:

```sh
install -m 755 cc-limits ~/.local/bin/cc-limits
```

## Usage

```sh
cc-limits                 # one shot, from cache if it is fresh
cc-limits --force         # ignore the cache, ask the server
cc-limits --watch         # live gauge, refresh every 120s (minimum 60)
cc-limits --watch 300     # ...every 300s
cc-limits --statusline    # one compact line, for the Claude Code status line
cc-limits --json          # raw API response for this window's account
cc-limits --json --all    # raw API responses for every account
cc-limits --accounts      # which accounts are declared, and this window's one
cc-limits --account флот  # work with this account only
cc-limits --refresh       # only refresh the cache and exit (for background use)
```

`NO_COLOR=1` disables color. `CC_LIMITS_FORCE_COLOR=1` forces it on when stdout
is not a TTY. `CC_LIMITS_RESERVE_5H` and `CC_LIMITS_RESERVE_7D` set the
[reserve](#shared-account-reserving-part-of-a-window).

## Status line integration

Add this to your `~/.claude/statusline-command.sh`, and the gauge shows up on
every turn:

```sh
limits=""
if [ -x "$HOME/.local/bin/cc-limits" ]; then
    limits=$(CC_LIMITS_FORCE_COLOR=1 "$HOME/.local/bin/cc-limits" --statusline 2>/dev/null)
    [ -n "$limits" ] && limits="  $limits"
fi

printf "%s%s" "$your_existing_prompt" "$limits"
```

A complete example is in [examples/statusline-command.sh](examples/statusline-command.sh).
If you do not have a status line yet, point Claude Code at it:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline-command.sh"
  }
}
```

`--statusline` never blocks on the network: it prints whatever is in the cache
and kicks off the refresh in the background. Measured cost is about 60 ms.

The last segment is the clock time of that cached reading. The cache lives up
to two minutes, longer while the endpoint is rate limiting, so without the
stamp there is no way to tell how old the numbers on screen are. It greys along
with the rest until the data passes five minutes, then turns yellow, then red
past fifteen.

## How it works

Claude Code gets its limit data from

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <accessToken>
anthropic-beta: oauth-2025-04-20
```

`cc-limits` calls the same endpoint with the same OAuth token, looked up the
way Claude Code looks it up:

1. `$CLAUDE_CODE_OAUTH_TOKEN`
2. macOS Keychain, service `Claude Code-credentials`
3. `$CLAUDE_CONFIG_DIR/.credentials.json` (default `~/.claude/.credentials.json`)

That is the single-account behavior; for several tokens see
[Multiple accounts](#multiple-accounts).

The token needs the `user:profile` scope, which a normal `/login` grants.
Nothing is written anywhere outside `$CLAUDE_CONFIG_DIR/cache`, and the token
is only ever sent to `api.anthropic.com`.

The response carries `five_hour` and `seven_day` utilization with reset
timestamps, per-model weekly limits, a breakdown of what consumed the week, and
extra-usage state. `--json` prints it untouched.

### Rate limiting

That endpoint has a request window of its own and answers `429` when you poll
it too hard. It does send a `Retry-After` header, but that header is not
trustworthy here: once the window is spent it keeps answering `429` while
advertising a retry of zero or one second, so obeying it literally produces a
tight retry loop.

So `cc-limits` waits for whichever is longer, the header or its own backoff:
60s on the first `429`, doubling per consecutive one, capped at 15 minutes, and
reset by the first success. The deadline and the strike count live in
`$CLAUDE_CONFIG_DIR/cache/cc-limits-throttle` (`cc-limits-throttle-<name>` for
a named account, since the strike count belongs to the token). While it waits
it serves the
cached numbers with their age labeled, and the label turns yellow past five
minutes and red past fifteen, because deciding how hard to work off stale
limit data is the mistake worth flagging. Hence also the 120s cache TTL and the
60s floor on `--watch`.

### The projection

Each refresh appends a sample to
`$CLAUDE_CONFIG_DIR/cache/cc-limits-history.jsonl`
(`cc-limits-history-<name>.jsonl` for a named account). The burn rate is the
slope
between the oldest and newest sample inside the current window.

A projection needs a real measurement span behind it, so one is only shown
once the samples cover at least 10 minutes for the 5-hour window and 2 hours
for the weekly one. Until then the row says `прогноз: мало замеров (N)` rather
than extrapolating a week out of six minutes of data. For the same reason the
deviation figure is suppressed during the first 2% of a window, where the
denominator is near zero and the ratio means nothing.

## Limitations

- The output strings are Russian only. The code has no i18n layer; adding one
  is a welcome contribution.
- Subscription accounts only. The endpoint is OAuth-based, so an
  `ANTHROPIC_API_KEY` setup has nothing to report.
- macOS and Linux. The Keychain path is macOS, everything else falls back to
  the credentials file.
- The endpoint is not a documented public API. It can change without notice,
  and this tool will break when it does.
- A `claude setup-token` token cannot report limits: it lacks the
  `user:profile` scope. That is the endpoint's rule, not this tool's -
  inference works with such a token, limit numbers do not.
- The current window's account is identified by reading the `claude` process
  environment. If Claude Code stops keeping the token there, or `ps` is
  unavailable, the account label disappears while the numbers stay.

## Tests

```sh
./tests/run.sh
```

No network needed: the cache and history are seeded by a fixture and the
window's account is set through `CLAUDE_CODE_OAUTH_TOKEN`. They cover the
`accounts` config parsing, the per-account cache and history files, the account
label in the status line, and the no-config behavior.

## License

MIT, see [LICENSE](LICENSE).
