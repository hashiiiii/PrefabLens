import { describe, expect, it } from "vitest";
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
