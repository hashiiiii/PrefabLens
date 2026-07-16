import { describe, expect, it, vi } from "vitest";
import { createAuthRetries } from "./authRetries";

describe("createAuthRetries", () => {
  it("runs every registered retry once on flush and empties the queue", () => {
    // Several files can sit on auth-error panels at once; one token landing retries them all,
    // and a second storage event (echo or unrelated pat rewrite) must not retry again.
    const retries = createAuthRetries();
    const a = vi.fn();
    const b = vi.fn();
    retries.add(a);
    retries.add(b);
    retries.flush();
    expect(a).toHaveBeenCalledTimes(1);
    expect(b).toHaveBeenCalledTimes(1);
    retries.flush();
    expect(a).toHaveBeenCalledTimes(1);
    expect(b).toHaveBeenCalledTimes(1);
  });

  it("keeps a retry registered during flush for the next flush", () => {
    // A retry that fails again re-registers itself from inside the flush: it must land in
    // the queue for the next token, not be wiped by the clear that is already in progress.
    const retries = createAuthRetries();
    const again = vi.fn();
    retries.add(() => retries.add(again));
    retries.flush();
    expect(again).not.toHaveBeenCalled(); // queued, not run in the same flush
    retries.flush();
    expect(again).toHaveBeenCalledTimes(1);
  });

  it("registers the same retry only once (set semantics)", () => {
    // Every scan re-runs show() on an error panel; identical registrations must not
    // stack up into duplicate requests when the token finally arrives.
    const retries = createAuthRetries();
    const retry = vi.fn();
    retries.add(retry);
    retries.add(retry);
    retries.flush();
    expect(retry).toHaveBeenCalledTimes(1);
  });
});
