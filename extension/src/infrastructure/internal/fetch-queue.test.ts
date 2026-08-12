import { describe, expect, it } from "vitest";
import { isRateLimited } from "../../application/gateway/github";
import { createQueue } from "./fetch-queue";

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
    // A user click does not wait behind the prefetch queue
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
    // Even if task() throws before it returns a Promise, active does not leak. With limit 1, a following task can run only if nothing leaked.
    const queue = createQueue(1);
    const syncThrow = (() => {
      throw new Error("sync boom");
    }) as () => Promise<never>;
    await expect(queue(syncThrow)).rejects.toThrow("sync boom");
    await expect(queue(async () => "next")).resolves.toBe("next");
  });

  it("keeps pumping when a queued task throws synchronously on dispatch", async () => {
    // A synchronous throw from a task dispatched inside pump()'s .finally does not become an unhandled rejection, and the caller's Promise settles
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

class VirtualClock {
  now = 0;
  private releasedThrough = 0;
  private sleepers = new Set<{ wakeAt: number; resolve: () => void }>();

  sleep = (milliseconds: number) => {
    this.now += milliseconds;
    if (this.now <= this.releasedThrough) return Promise.resolve();
    const wakeAt = this.now;
    return new Promise<void>((resolve) => {
      this.sleepers.add({ wakeAt, resolve });
    });
  };

  advanceTo(milliseconds: number): void {
    if (milliseconds < this.releasedThrough) throw new Error("Virtual clock cannot move backward");
    this.releasedThrough = milliseconds;
    for (const sleeper of this.sleepers) {
      if (sleeper.wakeAt > this.releasedThrough) continue;
      this.sleepers.delete(sleeper);
      sleeper.resolve();
    }
  }
}

const flush = () => new Promise((r) => setTimeout(r, 0));

describe("createQueue rate limit backoff", () => {
  it("retries a rate-limited task after the advised wait", async () => {
    const clock = new VirtualClock();
    const queue = createQueue(1, clock.sleep);
    let attempts = 0;
    const task = queue(async () => {
      attempts++;
      if (attempts === 1) throw { kind: "rate-limited", retryAfterMs: 5_000 };
      return "ok";
    });
    await flush();
    expect(clock.now).toBe(5_000);
    expect(attempts).toBe(1);
    clock.advanceTo(4_999);
    await flush();
    expect(attempts).toBe(1);
    clock.advanceTo(5_000);
    await expect(task).resolves.toBe("ok");
    expect(attempts).toBe(2);
  });

  it("caps the advised wait and falls back when no advice is given", async () => {
    const clock = new VirtualClock();
    const queue = createQueue(1, clock.sleep);
    // A 10-minute primary-limit advice is capped: a fast failure into the manual message beats a hang until the reset
    const capped = queue(async () => {
      throw { kind: "rate-limited", retryAfterMs: 600_000 };
    });
    const cappedRejects = expect(capped).rejects.toSatisfy(isRateLimited);
    await flush();
    expect(clock.now).toBe(60_000);
    clock.advanceTo(60_000);
    await flush();
    expect(clock.now).toBe(120_000);
    clock.advanceTo(120_000);
    await cappedRejects;
    // A secondary limit without headers gets the fallback wait
    const noAdvice = queue(async () => {
      throw { kind: "rate-limited" };
    });
    const noAdviceRejects = expect(noAdvice).rejects.toSatisfy(isRateLimited);
    await flush();
    expect(clock.now).toBe(150_000);
    clock.advanceTo(150_000);
    await flush();
    expect(clock.now).toBe(180_000);
    clock.advanceTo(180_000);
    await noAdviceRejects;
  });

  it("gives up after two retries and surfaces the original error", async () => {
    const clock = new VirtualClock();
    const queue = createQueue(1, clock.sleep);
    let attempts = 0;
    const task = queue(async () => {
      attempts++;
      throw { kind: "rate-limited", retryAfterMs: 1_000 };
    });
    const taskRejects = expect(task).rejects.toSatisfy(isRateLimited);
    await flush();
    expect(clock.now).toBe(1_000);
    clock.advanceTo(1_000);
    await flush();
    expect(clock.now).toBe(2_000);
    clock.advanceTo(2_000);
    await taskRejects;
    expect(attempts).toBe(3);
  });

  it("pauses queued work during backoff instead of failing it", async () => {
    const clock = new VirtualClock();
    const queue = createQueue(1, clock.sleep);
    let attempts = 0;
    const limited = queue(async () => {
      attempts++;
      if (attempts === 1) throw { kind: "rate-limited", retryAfterMs: 1_000 };
      return "retried";
    });
    await flush();
    let ran = false;
    const queued = queue(async () => {
      ran = true;
      return "later";
    });
    await flush();
    expect(clock.now).toBe(1_000);
    expect(ran).toBe(false);
    clock.advanceTo(999);
    await flush();
    expect(ran).toBe(false);
    clock.advanceTo(1_000);
    await expect(limited).resolves.toBe("retried");
    await expect(queued).resolves.toBe("later");
  });

  it("runs user tasks before a retried prefetch task after backoff", async () => {
    const clock = new VirtualClock();
    const queue = createQueue(1, clock.sleep);
    const order: string[] = [];
    let attempts = 0;
    const prefetchTask = queue(async () => {
      attempts++;
      if (attempts === 1) throw { kind: "rate-limited", retryAfterMs: 1_000 };
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
    expect(clock.now).toBe(1_000);
    expect(order).toEqual([]);
    clock.advanceTo(1_000);
    await Promise.all([prefetchTask, user]);
    expect(order).toEqual(["user", "prefetch-retry"]);
  });
});
