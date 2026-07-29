// Runtime-checked stand-in for banned `!`: present → return; absent → throw at call site.
export function must<T>(v: T | null | undefined): T {
  if (v == null) throw new Error("invariant violated: value is absent");
  return v;
}
