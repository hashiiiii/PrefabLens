/** Runtime-checked replacement for the banned `!` assertion: returns the value
 *  when present and fails loudly at the call site when the invariant breaks. */
export function must<T>(v: T | null | undefined): T {
  if (v == null) throw new Error("invariant violated: value is absent");
  return v;
}
