# LaxxPing

Hold a key, left-click where you want to ping, flick toward an icon, release.

A ping wheel for World of Warcraft retail (12.1.0, Midnight). Its pings target the
**environment only** — they pass through units and interface frames and land on the world,
whatever your Ping Target setting says — so a ping meant for the ground never gets stuck to
the tank.

## Why it exists

12.1.0 added a Ping Target setting and a keybind to toggle it, but toggling is modal: you are
either pinging units or you are not, and you have to remember which. LaxxPing makes it
per-ping instead. Nothing is toggled, no CVar is written, and there is no state to restore if
you change your mind halfway through a gesture.

## Using it

1. Bind **Ping Wheel** under Key Bindings → LaxxPing, or set it from the addon's own options.
2. `/laxxping` (or `/lping`, or the addon compartment) opens the options window.
3. Hold the key. Left-click where you want the ping. Flick toward an icon. Release.

Release without flicking and a plain ping lands exactly where you clicked — the only gesture
with no drift at all, and the most common ping.

While the key is held, left-click belongs to the wheel and the camera will not rotate. It is
handed straight back when you let go.

## Options

| Option | What it does |
|---|---|
| Ping wheel key | Sets the real keybind, so it also shows up in Blizzard's Key Bindings panel |
| Enabled | Turns the wheel off without unbinding its key |
| Environment only | Off sends ordinary pings that obey your Ping Target setting |
| Click without moving pings | Off makes a no-flick release cancel instead |
| Dead zone | How far you must flick before an icon is chosen — also how far the ping can miss by |
| Wheel radius | Appearance only; an icon is chosen by direction, not distance |
| Pings on the wheel | Which of the six ping types appear |

## How it works, and what constrains it

Worth writing down, because most of it is not guessable and all of it was measured in game
rather than inferred.

The ping is `/ping [@cursor] N` run from a secure button's macrotext. The `@cursor` token makes
Blizzard's `SendMacroPing` take its `forcePointPing` branch, which — in Blizzard's own words —
passes through all UI, ignores units, and ignores the Ping Target setting. Types are addressed
numerically because the slash handler's name keys are the localized `PING_TYPE_*` strings, so
`/ping attack` silently degrades to an untyped ping on any non-English client.

The mouse button that opens the wheel is claimed as an override binding **from inside a secure
snippet**, for exactly as long as the hold key is down. From Lua it would be blocked the moment
you entered combat, which is when a ping matters most. Which icon a release fires is decided
inside the snippet too, for the same reason.

Two constraints shaped the design:

- **The claimed button needs its own secure button.** A mouse click delivered to the same frame
  a held keybind is routed to destroys that keybind's pending up-edge, and the release is then
  never delivered. Measured, A/B'd, fixed by splitting the frames. They must not be merged back.
- **The ping lands where the cursor is at release**, not where you clicked. It cannot be
  otherwise: Blizzard's own wheel captures its target up front with
  `C_PingSecure.SetHitTestPingTarget` and fires it later with `SendHitTestPing`, and that
  namespace is `SecureOnly`. `Input.SetCursorPosition` would let the pointer be put back, but it
  is `RequiresLimitedInput` — gamepad hardware events only. So the dead zone *is* the accuracy
  budget, which is why it is small, visible while the wheel is open, and user-settable.

## Requirements

Retail 12.1.0 or later. No dependencies.

## Licence

MIT. See [LICENSE](LICENSE).
