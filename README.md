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
> my-project  git:(main)  5ч 24% -61% 1ч 54м|7д 19% -76%
```

Reading a row:

| Field | Meaning |
| --- | --- |
| `24.0%` | window utilization, green below 60, yellow 60-85, red above 85 |
| `сброс 1ч 54м` | time until the window resets |
| `откл -61%` | deviation from an even burn of the window budget: `0%` is exactly on pace, `-61%` means you are 61% slower than even (you have slack), `+20%` means 20% faster (you will hit the wall before the reset). Green at or below zero, yellow above |
| `хватит до сброса (8.5%/ч)` | measured burn rate and whether it lasts until the reset. Turns into a red `КОНЕЦ через 1ч 30м` when the projection says you run out first |

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
cc-limits --json          # raw API response
cc-limits --refresh       # only refresh the cache and exit (for background use)
```

`NO_COLOR=1` disables color. `CC_LIMITS_FORCE_COLOR=1` forces it on when stdout
is not a TTY.

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

The token needs the `user:profile` scope, which a normal `/login` grants.
Nothing is written anywhere outside `$CLAUDE_CONFIG_DIR/cache`, and the token
is only ever sent to `api.anthropic.com`.

The response carries `five_hour` and `seven_day` utilization with reset
timestamps, per-model weekly limits, a breakdown of what consumed the week, and
extra-usage state. `--json` prints it untouched.

### Rate limiting

That endpoint has its own sliding request window of roughly five minutes and
answers `429` with a `Retry-After` header when you poll it too hard. `cc-limits`
obeys the header: it records the deadline in
`$CLAUDE_CONFIG_DIR/cache/cc-limits-throttle`, serves the cached numbers with
their age labeled, and counts down to the retry instead of hammering the
server. Hence the 120s cache TTL and the 60s floor on `--watch`.

### The projection

Each refresh appends a sample to
`$CLAUDE_CONFIG_DIR/cache/cc-limits-history.jsonl`. The burn rate is the slope
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

## License

MIT, see [LICENSE](LICENSE).
