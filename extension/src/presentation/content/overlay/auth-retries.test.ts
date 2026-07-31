import { describe, expect, it, vi } from "vitest";
import { addAuthRetry, emptyAuthRetries, flushAuthRetries } from "./auth-retries";

describe("auth retries", () => {
  it("runs every registered retry once on flush and empties the queue", () => {
    // Several files can sit on auth-error panels at once; one token landing retries them all,
    // and a second storage event (echo or unrelated accessToken rewrite) must not retry again.
    const retries = emptyAuthRetries();
    const a = vi.fn();
    const b = vi.fn();
    addAuthRetry(retries, a);
    addAuthRetry(retries, b);
    flushAuthRetries(retries);
    expect(a).toHaveBeenCalledTimes(1);
    expect(b).toHaveBeenCalledTimes(1);
    flushAuthRetries(retries);
    expect(a).toHaveBeenCalledTimes(1);
    expect(b).toHaveBeenCalledTimes(1);
  });

  it("keeps a retry registered during flush for the next flush", () => {
    // A retry that fails again re-registers itself from inside the flush: it must land in
    // the queue for the next token, not be wiped by the clear that is already in progress.
    const retries = emptyAuthRetries();
    const again = vi.fn();
    addAuthRetry(retries, () => addAuthRetry(retries, again));
    flushAuthRetries(retries);
    expect(again).not.toHaveBeenCalled(); // queued, not run in the same flush
    flushAuthRetries(retries);
    expect(again).toHaveBeenCalledTimes(1);
  });

  it("registers the same retry only once (set semantics)", () => {
    // Every scan re-runs show() on an error panel; identical registrations must not
    // stack up into duplicate requests when the token finally arrives.
    const retries = emptyAuthRetries();
    const retry = vi.fn();
    addAuthRetry(retries, retry);
    addAuthRetry(retries, retry);
    flushAuthRetries(retries);
    expect(retry).toHaveBeenCalledTimes(1);
  });
});
