import { describe, expect, it } from "vitest";
import { addAuthRetry, emptyAuthRetries, flushAuthRetries } from "./auth-retries";

describe("auth retries", () => {
  it("runs every registered retry once on flush and empties the queue", () => {
    // Several files can sit on auth-error panels at once; one token landing retries them all,
    // and a second storage event (echo or unrelated accessToken rewrite) must not retry again.
    const retries = emptyAuthRetries();
    let a = 0;
    let b = 0;
    addAuthRetry(retries, () => void a++);
    addAuthRetry(retries, () => void b++);
    flushAuthRetries(retries);
    expect(a).toBe(1);
    expect(b).toBe(1);
    flushAuthRetries(retries);
    expect(a).toBe(1);
    expect(b).toBe(1);
  });

  it("keeps a retry registered during flush for the next flush", () => {
    // A retry that fails again re-registers itself from inside the flush: it must land in
    // the queue for the next token, not be wiped by the clear that is already in progress.
    const retries = emptyAuthRetries();
    let againRuns = 0;
    const again = () => void againRuns++;
    addAuthRetry(retries, () => addAuthRetry(retries, again));
    flushAuthRetries(retries);
    expect(againRuns).toBe(0); // queued, not run in the same flush
    flushAuthRetries(retries);
    expect(againRuns).toBe(1);
  });

  it("registers the same retry only once (set semantics)", () => {
    // Every scan re-runs show() on an error panel; identical registrations must not
    // stack up into duplicate requests when the token finally arrives.
    const retries = emptyAuthRetries();
    let runs = 0;
    const retry = () => void runs++;
    addAuthRetry(retries, retry);
    addAuthRetry(retries, retry);
    flushAuthRetries(retries);
    expect(runs).toBe(1);
  });
});
