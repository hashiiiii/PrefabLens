import { describe, expect, it } from 'vitest';
import { createQueue } from './queue';

// 手動で解決できる deferred を並べ、実行順と同時実行数を観測する
function deferred(): { promise: Promise<void>; resolve: () => void } {
  let resolve!: () => void;
  const promise = new Promise<void>((r) => { resolve = r; });
  return { promise, resolve };
}

describe('createQueue', () => {
  it('caps concurrent tasks at the limit', async () => {
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
    expect(maxActive).toBe(2); // secondary rate limit 回避: 同時 2 本を超えない
    gate.resolve();
    await Promise.all(tasks);
    expect(maxActive).toBe(2);
  });

  it('runs front tasks before queued ones', async () => {
    // ユーザークリックがプリフェッチの行列に並ばされない
    const queue = createQueue(1);
    const order: string[] = [];
    const gate = deferred();
    const first = queue(async () => { await gate.promise; order.push('running'); });
    const prefetchTask = queue(async () => { order.push('prefetch'); });
    const user = queue(async () => { order.push('user'); }, { front: true });
    gate.resolve();
    await Promise.all([first, prefetchTask, user]);
    expect(order).toEqual(['running', 'user', 'prefetch']);
  });

  it('keeps pumping after a task rejects', async () => {
    // 1 つの失敗でキューが詰まると、以降の全フェッチが永久に待つ
    const queue = createQueue(1);
    await expect(queue(async () => { throw new Error('boom'); })).rejects.toThrow('boom');
    await expect(queue(async () => 'next')).resolves.toBe('next');
  });
});
