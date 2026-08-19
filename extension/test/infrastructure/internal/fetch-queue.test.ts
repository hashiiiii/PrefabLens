import { describe, expect, it } from "vitest";
import { isRateLimited } from "../../../src/application/gateway/github";
import { createQueue } from "../../../src/infrastructure/internal/fetch-queue";

// Manual deferreds expose the task order and concurrency.
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
    // GitHub applies a secondary rate limit above two concurrent requests.
    expect(maxActive).toBe(2);
    gate.resolve();
    await Promise.all(tasks);
    expect(maxActive).toBe(2);
  });

  it("runs front tasks before queued ones", async () => {
    // A user click must not wait behind the prefetch queue.
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
    // If one failure stops the queue, every later fetch waits forever.
    const queue = createQueue(1);
    await expect(
      queue(async () => {
        throw new Error("boom");
      }),
    ).rejects.toThrow("boom");
    await expect(queue(async () => "next")).resolves.toBe("next");
  });

  it("normalizes a synchronous throw into a rejection without losing a slot", async () => {
    // A synchronous throw can occur before task() returns a Promise.
    // The next task runs only when the active slot returns to the queue.
    const queue = createQueue(1);
    const syncThrow = (() => {
      throw new Error("sync boom");
    }) as () => Promise<never>;
    await expect(queue(syncThrow)).rejects.toThrow("sync boom");
    await expect(queue(async () => "next")).resolves.toBe("next");
  });

  it("keeps pumping when a queued task throws synchronously on dispatch", async () => {
    // pump() dispatches this task from a Promise callback.
    // The synchronous throw must reject the task and release the queue.
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
    const task = queue(async () => {
      if (clock.now < 5_000) throw { kind: "rate-limited", retryAfterMs: 5_000 };
      return "ok";
    });
    const timeline: string[] = [];
    void task.then((value) => timeline.push(value));
    await flush();
    expect(clock.now).toBe(5_000);
    clock.advanceTo(4_999);
    await flush();
    expect(timeline).toEqual([]);
    clock.advanceTo(5_000);
    await expect(task).resolves.toBe("ok");
    expect(timeline).toEqual(["ok"]);
  });

  it("caps each rate-limit wait at sixty seconds", async () => {
    const clock = new VirtualClock();
    const queue = createQueue(1, clock.sleep);
    // A ten-minute wait prevents the UI from showing the manual retry message.
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
  });

  it("uses thirty seconds when a response has no retry advice", async () => {
    const clock = new VirtualClock();
    const queue = createQueue(1, clock.sleep);
    const noAdvice = queue(async () => {
      throw { kind: "rate-limited" };
    });
    const noAdviceRejects = expect(noAdvice).rejects.toSatisfy(isRateLimited);
    await flush();
    expect(clock.now).toBe(30_000);
    clock.advanceTo(30_000);
    await flush();
    expect(clock.now).toBe(60_000);
    clock.advanceTo(60_000);
    await noAdviceRejects;
  });

  it("gives up after two retries and surfaces the original error", async () => {
    const clock = new VirtualClock();
    const queue = createQueue(1, clock.sleep);
    const task = queue(async () => {
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
  });

  it("pauses queued work during backoff instead of failing it", async () => {
    const clock = new VirtualClock();
    const queue = createQueue(1, clock.sleep);
    const timeline: string[] = [];
    const limited = queue(async () => {
      if (clock.now < 1_000) throw { kind: "rate-limited", retryAfterMs: 1_000 };
      timeline.push("retried");
      return "retried";
    });
    await flush();
    const queued = queue(async () => {
      timeline.push("later");
      return "later";
    });
    await flush();
    expect(clock.now).toBe(1_000);
    expect(timeline).toEqual([]);
    clock.advanceTo(999);
    await flush();
    expect(timeline).toEqual([]);
    clock.advanceTo(1_000);
    await expect(Promise.all([limited, queued])).resolves.toEqual(["retried", "later"]);
    expect(timeline).toEqual(["retried", "later"]);
  });

  it("runs user tasks before a retried prefetch task after backoff", async () => {
    const clock = new VirtualClock();
    const queue = createQueue(1, clock.sleep);
    const order: string[] = [];
    const prefetchTask = queue(async () => {
      if (clock.now < 1_000) throw { kind: "rate-limited", retryAfterMs: 1_000 };
      order.push("prefetch-retry");
    });
    await flush();
    // The user request must not starve while the queue waits to retry prefetch work.
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
