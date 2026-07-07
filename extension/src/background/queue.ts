type Job = { run: () => Promise<unknown>; resolve: (v: unknown) => void; reject: (e: unknown) => void };

export type Queue = <T>(task: () => Promise<T>, opts?: { front?: boolean }) => Promise<T>;

/** REST の同時実行数を絞る(GitHub secondary rate limit はバーストで発動する)。
 *  front はユーザー操作由来の割り込み用: プリフェッチの行列を追い越す。 */
export function createQueue(limit: number): Queue {
  const pending: Job[] = [];
  let active = 0;
  const pump = (): void => {
    while (active < limit && pending.length) {
      const job = pending.shift()!;
      active++;
      // 同期 throw も reject に正規化する: ここで漏れると active が戻らず、キューが永久に詰まる
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
