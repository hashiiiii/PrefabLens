import { isRateLimited } from "../../application/gateway/github";
import { must } from "../../internal/must";

type Job = {
  run: () => Promise<unknown>;
  resolve: (v: unknown) => void;
  reject: (e: unknown) => void;
  front: boolean;
  retries: number;
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
      // Normalize sync throws into rejections: a leak here jams the queue forever
      Promise.resolve()
        .then(job.run)
        .then(
          (v) => {
            active--;
            job.resolve(v);
            pump();
          },
          (e: unknown) => {
            active--;
            if (isRateLimited(e) && job.retries < MAX_RATE_LIMIT_RETRIES) {
              job.retries++;
              enqueue(job);
              pauseFor(Math.min(e.retryAfterMs ?? BACKOFF_FALLBACK_MS, BACKOFF_CAP_MS));
            } else {
              job.reject(e);
            }
            pump();
          },
        );
    }
  };

  return <T>(task: () => Promise<T>, opts?: { front?: boolean }) =>
    new Promise<T>((resolve, reject) => {
      enqueue({
        run: task,
        resolve: resolve as (v: unknown) => void,
        reject,
        front: opts?.front === true,
        retries: 0,
      });
      pump();
    });
}
