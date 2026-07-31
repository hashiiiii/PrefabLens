export type AuthRetries = {
  add(retry: () => void): void;
  flush(): void;
};

// Auth-blocked panels register a retry; a token landing in storage flushes them all
export function createAuthRetries(): AuthRetries {
  const retries = new Set<() => void>();
  return {
    add: (retry) => void retries.add(retry),
    flush() {
      // Clear first: a retry that fails again re-registers for the next token
      const pending = [...retries];
      retries.clear();
      for (const retry of pending) retry();
    },
  };
}
