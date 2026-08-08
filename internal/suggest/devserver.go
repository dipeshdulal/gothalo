package suggest

import "strconv"

// maxDevServerChips caps what this one source may contribute to a row of [Max].
//
// A pane running a frontend and an API is two chips, and both are worth a tap.
// A pane running five is a microservice stack, and turning the whole row into a
// port list would push out the "resolve this conflict" chip that is the reason
// the row is worth reading. Two is where "here are your servers" stops and "here
// is a directory of servers" starts — and `GET /ports` is still the place to go
// for the full list.
const maxDevServerChips = 2

// devServers turns the listeners already attributed to this pane into chips.
//
// This is the dev-server preview feature, folded into the suggestion mechanism
// rather than living beside it. Everything expensive — finding the listeners,
// proving they speak HTTP, walking the process tree to a pane's shell pid,
// deciding whether the phone can reach them — happened in internal/ports before
// the observation reached here. What is left is presentation and ranking, which
// is exactly the part that belongs in the same place as every other chip.
//
// Three outcomes now, and the middle one is what the relay bought:
//
//   - Bound wide, reachable directly (`url` present, not relayed) → "Open :5173",
//     straight to the system browser. The fastest path, and it stays the one
//     taken whenever it exists.
//   - Bound to loopback but relayed (`url` present, relayed) → "Open :8124", via
//     a listener the bridge opened and splices to 127.0.0.1. The chip is a link
//     rather than an explanation. The explanation survives in `note`, because a
//     user who would rather rebind than proxy still wants to know about
//     `--host` — the app hangs it off a long press.
//   - Bound to loopback with no relay (`url` absent) → a note, as before. The
//     server is genuinely up, and "vite is on :5174, it's just bound to
//     127.0.0.1" is the answer to the question the user is actually asking when
//     the chip they expected isn't a link. Hiding it would leave them guessing;
//     showing it as a tappable chip that does nothing would break the rule the
//     whole surface rests on.
func devServers(p Pane) []Suggestion {
	out := make([]Suggestion, 0, len(p.Servers))
	for _, s := range p.Servers {
		if s.Port <= 0 {
			continue
		}
		if len(out) == maxDevServerChips {
			break
		}
		port := ":" + strconv.Itoa(s.Port)
		switch {
		case s.URL == "":
			// Up, and nothing can reach it — not even through the bridge.
			out = append(out, Suggestion{
				Kind:      KindDevServerLocal,
				Performer: PerformerApp,
				Label:     port + " is local-only",
				Detail:    detail(s.Proc, "bound to localhost"),
				Action:    ActionShowNote,
				Params: map[string]string{
					"port": strconv.Itoa(s.Port),
					"note": localOnlyNote(s),
				},
				Rank: RankDevServerLocal,
			})
		case s.Loopback:
			// Reachable only because the bridge is dialling 127.0.0.1 for you.
			// Still KindDevServerLocal: the icon stays distinct, the chip ranks
			// below a direct one, and the app knows a note is attached.
			out = append(out, Suggestion{
				Kind:      KindDevServerLocal,
				Performer: PerformerApp,
				Label:     "Open " + port,
				Detail:    detail(s.Proc, "via the bridge"),
				Action:    ActionOpenURL,
				Params: map[string]string{
					"url":  s.URL,
					"port": strconv.Itoa(s.Port),
					"note": relayedNote(s),
				},
				Rank: RankDevServerLocal,
			})
		default:
			out = append(out, Suggestion{
				Kind:      KindDevServer,
				Performer: PerformerApp,
				Label:     "Open " + port,
				Detail:    detail(s.Proc, "serving"),
				Action:    ActionOpenURL,
				Params: map[string]string{
					"url":  s.URL,
					"port": strconv.Itoa(s.Port),
				},
				Rank: RankDevServer,
			})
		}
	}
	// Listeners arrive sorted by port, and the ranks above are per-kind
	// constants, so a pane serving on 5173 and 5174 keeps that order through
	// For's stable sort. Deliberately not ranked by port number: a lower port is
	// not a more useful server, and making it one would reorder the row every
	// time a dev server restarted on a different port.
	return out
}

// detail composes the chip's second line: the process name when the scan named
// one ("node · serving"), the bare state otherwise. The process name is what
// distinguishes your Vite from the Postgres-adjacent thing you forgot about.
func detail(proc, state string) string {
	if proc == "" {
		return state
	}
	return proc + " · " + state
}

// localOnlyNote is the whole payload of a KindDevServerLocal tap: what is true
// and what to do about it.
//
// It names the flag rather than describing the situation, because the situation
// is already on the chip. A phone is the worst place to work out that Vite
// defaults to 127.0.0.1 and that `--host` is the fix, and it is the best place
// to be told.
// relayedNote is what a long press on a relayed chip says: the link works, here
// is what it is actually doing, and here is how to stop needing it.
//
// Kept rather than dropped once the chip became a link, because "your server is
// bound to localhost" is still true and still worth acting on — the relay is a
// convenience, and a direct bind is faster, has no extra hop, and survives the
// bridge restarting.
func relayedNote(s Server) string {
	who := "This server"
	if s.Proc != "" {
		who = s.Proc
	}
	return who + " is bound to 127.0.0.1, so the phone cannot reach it directly. " +
		"The bridge is relaying it: your browser talks to the bridge, and the " +
		"bridge dials 127.0.0.1 on the host.\n\n" +
		"That works, including hot reload. To skip the extra hop, restart the " +
		"server bound to all interfaces (most dev servers take --host, or a " +
		"host of 0.0.0.0) and the chip will link straight to it."
}

func localOnlyNote(s Server) string {
	who := "This server"
	if s.Proc != "" {
		who = s.Proc
	}
	return who + " is serving on port " + strconv.Itoa(s.Port) +
		", but it is bound to 127.0.0.1 — nothing on the tailnet can reach it, " +
		"including this phone.\n\n" +
		"Restart it bound to all interfaces (most dev servers take --host, " +
		"or a host of 0.0.0.0) and the chip becomes a link."
}
