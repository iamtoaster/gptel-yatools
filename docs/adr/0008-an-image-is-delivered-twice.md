# 0008 — An image is delivered twice, and both deliveries are needed

## Status

Accepted.

## Context

`read_path` refused binary files with a notice telling the model to run
`file` instead.  For an image that is the wrong answer twice over: the model
cannot see it, and a multimodal model would have understood it immediately.
gptel already knows how to send an image — a `gptel-context` entry of the
form `(PATH :mime MIME)` is base64-encoded into a provider-shaped content
block (`image_url` with a data URL for OpenAI, a `source` object for
Anthropic, `inline_data` for Gemini) — so the obvious implementation is to
push such an entry from the tool and let gptel carry it.

That implementation does not work, and the reason is a fact about gptel's
request lifecycle rather than about media:

- `gptel--inject-media` runs **once**, while the request payload is being
  built, in `gptel-request`'s INIT (`gptel-request.el:2402`).
- The tool loop does not rebuild the payload.  `TRET → WAIT` re-fires the
  same `:data` (`gptel-request--transitions`, `gptel-request.el:1831`), so
  everything a tool call changes about `gptel-context` is invisible until a
  *later* request is built from the buffer.

A tool that only pushed a context entry would therefore answer
"attached" and show the model nothing — worse than the binary notice, which
at least told the model where it stood.

The other half of the question is lifetime.  A `gptel-context` entry
travels with every request until it is removed, which is what makes the
image available to the turns after the one that asked for it — and is also
what makes it cost its tokens again on each of them.

## Decision

**Two deliveries, with different lifetimes, and both are deliberate.**

1. **This request.** `gptel-yatools-media--pending`, a buffer-local queue,
   holds what was attached while the request was being answered.
   `gptel-yatools--deliver-attached-media` is advice on `gptel--handle-wait`
   and drains it into the payload about to be sent.
2. **The rest of the chat.** The same attach also prepends a
   `gptel-context` entry, tagged with `:gptel-yatools-media`, so later
   requests carry the image the ordinary way.

The queue is cleared when a request starts.  An image attached and never
delivered — the request died between the call and the send — is already in
`gptel-context`, which the next build reads; leaving it queued would put the
same image in the payload twice.

Delivery goes into the **first message the user wrote**, because that is
where gptel puts the media it carries, and because the alternatives are
worse:

- A message of its own, appended after the tool results, is the shape
  macher-agent uses.  It separates a tool result from the tool call it
  answers, which the Anthropic API refuses; gptel's own Anthropic backend
  moved its media injection from the last prompt to the first for what look
  like the same reasons (the commented-out code in `gptel-anthropic.el`).
- Prepending to the tool-result message itself would satisfy Anthropic's
  "tool results first" rule, but only by writing a content block here — and
  the shape of that block is the backend's business.

So the block is never written here.  `gptel--inject-media` is asked, with
`gptel-context` bound to just the pending entries; the one message it is
handed is a real message plist out of `:data`, and `plist-put` on it lands
in the payload.  Which plist key holds the conversation — `:messages`,
`:input` or `:contents` — is the one piece of backend shape this package
names, in `gptel-yatools-media--message-keys`.

## Consequences

- An image is visible in the turn it was asked for, and in every turn
  after it, without the model having to ask again.  Removing it is a
  command, not a timeout.
- The queue is a second buffer-local store next to the VFS, with the same
  "the chat owns it" rule, and the same consequence for a subagent: a child
  gets the in-turn delivery and not the persistence, because a child's
  context is deliberately empty.  A child that reads an image sees it once.
- Prepending to the first user message invalidates any prompt cache over
  the early messages on the turn an image arrives.  The alternative —
  appending — is a malformed request on at least one provider, so the cost
  is accepted and stated here rather than discovered later.
- Two more advice sites on gptel (`gptel--handle-wait`, `gptel-request`),
  both named in the gptel-surface test so a version bump reports them.
- Delivery failure is logged, not signalled: a signal inside the state
  machine would strand the request in WAIT.  The image is still in
  `gptel-context`, so the worst case is that the model sees it one request
  later than it should.
- Only images.  PDF, audio and video would each need a decision about the
  model capability that accepts them, and nobody has asked for one.  The
  sniffing table is the place to add a format, and the size limit is shared.
