// Auth-blocked panels register a retry; a token landing in storage flushes them all
export function flushAuthRetries(retries: Set<() => void>): void {
  // Clear first: a retry that fails again re-registers for the next token
  const pending = [...retries];
  retries.clear();
  for (const retry of pending) retry();
}
