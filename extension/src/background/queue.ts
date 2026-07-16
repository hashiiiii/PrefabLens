import { RateLimitError } from "../github/client";
import { must } from "../util/must";

type Job = {
  run: () => Promise<unknown>;
  resolve: (v: unknown) => void;
  reject: (e: unknown) => void;
  front: boolean;
  retries: number;
};

export type Queue = <T>(task: () => Promise<T>, opts?: { front?: boolean }) => Promise<T>;

const MAX_RATE_LIMIT_RETRIES = 2; // per job, on top of the initial attempt
const BACKOFF_CAP_MS = 60_000; // a primary-limit reset can be an hour away: fail into the manual message instead
const BACKOFF_FALLBACK_MS = 30_000; // secondary limits sometimes advise nothing; they clear within a minute

/** Throttles REST concurrency (GitHub secondary rate limits trigger on bursts).
 *  front is for user-action interrupts: it jumps the prefetch queue.
 *  A RateLimitError pauses the whole queue for the advised (capped) duration and re-enqueues
 *  the failed job by lane — front jobs re-enter at the front so prefetch never starves them. */
export function createQueue(
  limit: number,
  sleep: (ms: number) => Promise<void> = (ms) => new Promise((r) => setTimeout(r, ms)),
): Queue {
  const pending: Job[] = [];
  let active = 0;
  let paused = false;

  const pauseFor = (ms: number): void => {
    if (paused) return; // concurrent failures share the first backoff; later ones just requeue
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
      // Normalize even a synchronous throw into a rejection: a leak here leaves active undecremented and jams the queue forever
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
            if (e instanceof RateLimitError && job.retries < MAX_RATE_LIMIT_RETRIES) {
              job.retries++;
              if (job.front) pending.unshift(job);
              else pending.push(job);
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
      const job: Job = {
        run: task,
        resolve: resolve as (v: unknown) => void,
        reject,
        front: opts?.front === true,
        retries: 0,
      };
      if (job.front) pending.unshift(job);
      else pending.push(job);
      pump();
    });
}
