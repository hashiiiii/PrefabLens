import { describe, expect, it } from "vitest";
import { RateLimitError } from "../github/client";
import { must } from "../util/must";
import { createQueue } from "./queue";

// Line up manually-resolvable deferreds to observe execution order and concurrency
function deferred(): { promise: Promise<void>; resolve: () => void } {
  let resolve!: () => void;
  const promise = new Promise<void>((r) => {
    resolve = r;
  });
  return { promise, resolve };
}

describe("createQueue", () => {
  it("caps concurrent tasks at the limit", async () => {
    const queue = createQueue(2);
    let active = 0;
    let maxActive = 0;
    const gate = deferred();
    const tasks = Array.from({ length: 5 }, () =>
      queue(async () => {
        active++;
        maxActive = Math.max(maxActive, active);
        await gate.promise;
        active--;
      }),
    );
    await new Promise((r) => setTimeout(r, 0));
    expect(maxActive).toBe(2); // avoids the secondary rate limit: never exceeds 2 concurrent
    gate.resolve();
    await Promise.all(tasks);
    expect(maxActive).toBe(2);
  });

  it("runs front tasks before queued ones", async () => {
    // A user click isn't made to wait behind the prefetch queue
    const queue = createQueue(1);
    const order: string[] = [];
    const gate = deferred();
    const first = queue(async () => {
      await gate.promise;
      order.push("running");
    });
    const prefetchTask = queue(async () => {
      order.push("prefetch");
    });
    const user = queue(
      async () => {
        order.push("user");
      },
      { front: true },
    );
    gate.resolve();
    await Promise.all([first, prefetchTask, user]);
    expect(order).toEqual(["running", "user", "prefetch"]);
  });

  it("keeps pumping after a task rejects", async () => {
    // If one failure jams the queue, every subsequent fetch waits forever
    const queue = createQueue(1);
    await expect(
      queue(async () => {
        throw new Error("boom");
      }),
    ).rejects.toThrow("boom");
    await expect(queue(async () => "next")).resolves.toBe("next");
  });

  it("normalizes a synchronous throw into a rejection without losing a slot", async () => {
    // Even if task() throws before returning a Promise, active doesn't leak: with limit 1, a following task running means nothing leaked
    const queue = createQueue(1);
    const syncThrow = (() => {
      throw new Error("sync boom");
    }) as () => Promise<never>;
    await expect(queue(syncThrow)).rejects.toThrow("sync boom");
    await expect(queue(async () => "next")).resolves.toBe("next");
  });

  it("keeps pumping when a queued task throws synchronously on dispatch", async () => {
    // A synchronous throw from a task dispatched inside pump()'s .finally doesn't become an unhandled rejection, and the caller's Promise settles
    const queue = createQueue(1);
    const gate = deferred();
    const first = queue(async () => {
      await gate.promise;
    });
    const syncThrow = (() => {
      throw new Error("boom");
    }) as () => Promise<never>;
    const bad = queue(syncThrow);
    const good = queue(async () => "ok");
    gate.resolve();
    await first;
    await expect(bad).rejects.toThrow("boom");
    await expect(good).resolves.toBe("ok");
  });
});

// Hand-controlled sleep: records requested waits, resumes only when the test says so
function manualSleep() {
  const waits: Array<{ ms: number; resolve: () => void }> = [];
  const sleep = (ms: number) =>
    new Promise<void>((resolve) => {
      waits.push({ ms, resolve });
    });
  return { sleep, waits };
}

const flush = () => new Promise((r) => setTimeout(r, 0));

describe("createQueue rate limit backoff", () => {
  it("retries a rate-limited task after the advised wait", async () => {
    const { sleep, waits } = manualSleep();
    const queue = createQueue(1, sleep);
    let attempts = 0;
    const task = queue(async () => {
      attempts++;
      if (attempts === 1) throw new RateLimitError("limited", 5_000);
      return "ok";
    });
    await flush();
    expect(waits.map((w) => w.ms)).toEqual([5_000]); // paused for exactly the advice
    expect(attempts).toBe(1); // nothing reruns while paused
    must(waits[0]).resolve();
    await expect(task).resolves.toBe("ok");
    expect(attempts).toBe(2);
  });

  it("caps the advised wait and falls back when no advice is given", async () => {
    const { sleep, waits } = manualSleep();
    const queue = createQueue(1, sleep);
    // A 10-minute primary-limit advice is capped: better to fail into the manual message than hang until the reset
    const capped = queue(async () => {
      throw new RateLimitError("limited", 600_000);
    });
    const cappedRejects = expect(capped).rejects.toBeInstanceOf(RateLimitError);
    await flush();
    must(waits[0]).resolve();
    await flush();
    must(waits[1]).resolve();
    await cappedRejects;
    // A secondary limit without headers gets the fallback wait
    const noAdvice = queue(async () => {
      throw new RateLimitError("limited");
    });
    const noAdviceRejects = expect(noAdvice).rejects.toBeInstanceOf(RateLimitError);
    await flush();
    must(waits[2]).resolve();
    await flush();
    must(waits[3]).resolve();
    await noAdviceRejects;
    expect(waits.map((w) => w.ms)).toEqual([60_000, 60_000, 30_000, 30_000]);
  });

  it("gives up after two retries and surfaces the original error", async () => {
    const { sleep, waits } = manualSleep();
    const queue = createQueue(1, sleep);
    let attempts = 0;
    const task = queue(async () => {
      attempts++;
      throw new RateLimitError("limited", 1_000);
    });
    const taskRejects = expect(task).rejects.toBeInstanceOf(RateLimitError);
    await flush();
    must(waits[0]).resolve(); // resume → retry 1 fails
    await flush();
    must(waits[1]).resolve(); // resume → retry 2 fails → reject
    await taskRejects;
    expect(attempts).toBe(3); // initial + 2 retries, then the manual-retry UI takes over
    expect(waits).toHaveLength(2);
  });

  it("pauses queued work during backoff instead of failing it", async () => {
    const { sleep, waits } = manualSleep();
    const queue = createQueue(1, sleep);
    let attempts = 0;
    const limited = queue(async () => {
      attempts++;
      if (attempts === 1) throw new RateLimitError("limited", 1_000);
      return "retried";
    });
    await flush();
    let ran = false;
    const queued = queue(async () => {
      ran = true;
      return "later";
    });
    await flush();
    expect(ran).toBe(false); // held back while the queue is paused, not rejected
    must(waits[0]).resolve();
    await expect(limited).resolves.toBe("retried");
    await expect(queued).resolves.toBe("later");
  });

  it("runs user tasks before a retried prefetch task after backoff", async () => {
    const { sleep, waits } = manualSleep();
    const queue = createQueue(1, sleep);
    const order: string[] = [];
    let attempts = 0;
    const prefetchTask = queue(async () => {
      attempts++;
      if (attempts === 1) throw new RateLimitError("limited", 1_000);
      order.push("prefetch-retry");
    });
    await flush();
    // The user clicks while the queue is backing off: their request must not starve
    const user = queue(
      async () => {
        order.push("user");
      },
      { front: true },
    );
    await flush();
    must(waits[0]).resolve();
    await Promise.all([prefetchTask, user]);
    expect(order).toEqual(["user", "prefetch-retry"]);
  });
});
