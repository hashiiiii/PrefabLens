import { isRateLimited } from "../../application/gateway/github";
import { must } from "../../internal/must";

type Job = {
  run(): void;
  front: boolean;
};

export type Queue = <T>(task: () => Promise<T>, opts?: { front?: boolean }) => Promise<T>;

const MAX_RATE_LIMIT_RETRIES = 2; // per job, on top of the initial attempt
const BACKOFF_CAP_MS = 60_000; // primary-limit reset can be an hour: fail into the manual message instead
const BACKOFF_FALLBACK_MS = 30_000; // Secondary limits sometimes advise nothing. They clear within a minute.

// Throttles REST concurrency. front gives user actions priority over prefetch entries.
// rate-limited pauses the whole queue and re-enqueues by lane so prefetch never starves front.
export function createQueue(
  limit: number,
  sleep: (ms: number) => Promise<void> = (ms) => new Promise((r) => setTimeout(r, ms)),
): Queue {
  const pending: Job[] = [];
  let active = 0;
  let paused = false;

  const enqueue = (job: Job): void => {
    if (job.front) pending.unshift(job);
    else pending.push(job);
  };

  const pauseFor = (ms: number): void => {
    if (paused) return; // Concurrent failures share the first backoff. Later ones only requeue.
    paused = true;
    void sleep(ms).then(() => {
      paused = false;
      pump();
    });
  };

  const pump = (): void => {
    while (!paused && active < limit && pending.length) {
      const job = must(pending.shift());
      active++;
      job.run();
    }
  };

  return <T>(task: () => Promise<T>, opts?: { front?: boolean }) =>
    new Promise<T>((resolve, reject) => {
      let retries = 0;
      const job: Job = {
        front: opts?.front === true,
        run() {
          // The closure preserves T. Normalize sync throws so a task cannot leak an active slot.
          void Promise.resolve()
            .then(task)
            .then(
              (value) => {
                active--;
                resolve(value);
                pump();
              },
              (cause: unknown) => {
                active--;
                if (isRateLimited(cause) && retries < MAX_RATE_LIMIT_RETRIES) {
                  retries++;
                  enqueue(job);
                  pauseFor(Math.min(cause.retryAfterMs ?? BACKOFF_FALLBACK_MS, BACKOFF_CAP_MS));
                } else {
                  reject(cause);
                }
                pump();
              },
            );
        },
      };
      enqueue(job);
      pump();
    });
}
