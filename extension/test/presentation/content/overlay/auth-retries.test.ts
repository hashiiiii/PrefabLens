import { describe, expect, it } from "vitest";
import { flushAuthRetries } from "../../../../src/presentation/content/overlay/auth-retries";

describe("auth retries", () => {
  it("runs every registered retry once on flush and empties the queue", () => {
    // Several files can sit on auth-error panels at once. One token that lands retries them
    // all, and a second storage event (echo or unrelated accessToken rewrite) must not retry again.
    const retries = new Set<() => void>();
    let a = 0;
    let b = 0;
    retries.add(() => void a++);
    retries.add(() => void b++);
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
    const retries = new Set<() => void>();
    let againRuns = 0;
    const again = () => void againRuns++;
    retries.add(() => void retries.add(again));
    flushAuthRetries(retries);
    expect(againRuns).toBe(0); // queued, not run in the same flush
    flushAuthRetries(retries);
    expect(againRuns).toBe(1);
  });
});
