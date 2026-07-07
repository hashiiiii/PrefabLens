type Job = { run: () => Promise<unknown>; resolve: (v: unknown) => void; reject: (e: unknown) => void };

export type Queue = <T>(task: () => Promise<T>, opts?: { front?: boolean }) => Promise<T>;

/** Throttles REST concurrency (GitHub secondary rate limits trigger on bursts).
 *  front is for user-action interrupts: it jumps the prefetch queue. */
export function createQueue(limit: number): Queue {
  const pending: Job[] = [];
  let active = 0;
  const pump = (): void => {
    while (active < limit && pending.length) {
      const job = pending.shift()!;
      active++;
      // Normalize even a synchronous throw into a rejection: a leak here leaves active undecremented and jams the queue forever
      Promise.resolve()
        .then(job.run)
        .then(job.resolve, job.reject)
        .finally(() => {
          active--;
          pump();
        });
    }
  };
  return <T>(task: () => Promise<T>, opts?: { front?: boolean }) =>
    new Promise<T>((resolve, reject) => {
      const job: Job = { run: task, resolve: resolve as (v: unknown) => void, reject };
      if (opts?.front) pending.unshift(job);
      else pending.push(job);
      pump();
    });
}
