export type AuthRetries = {
  add(retry: () => void): void;
  flush(): void;
};

/** Files whose panels are stuck on an auth error register a retry; a token landing
 *  in storage flushes them all at once. */
export function createAuthRetries(): AuthRetries {
  const retries = new Set<() => void>();
  return {
    add: (retry) => void retries.add(retry),
    flush() {
      // Clear before running: a retry that fails again re-registers itself for the next token.
      const pending = [...retries];
      retries.clear();
      for (const retry of pending) retry();
    },
  };
}
