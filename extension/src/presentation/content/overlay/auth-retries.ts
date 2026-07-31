export type AuthRetriesState = { retries: Set<() => void> };

// Auth-blocked panels register a retry; a token landing in storage flushes them all
export function emptyAuthRetries(): AuthRetriesState {
  return { retries: new Set() };
}

export function addAuthRetry(state: AuthRetriesState, retry: () => void): void {
  state.retries.add(retry);
}

export function flushAuthRetries(state: AuthRetriesState): void {
  // Clear first: a retry that fails again re-registers for the next token
  const pending = [...state.retries];
  state.retries.clear();
  for (const retry of pending) retry();
}
