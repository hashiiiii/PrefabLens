// A runtime-checked stand-in for the banned `!`: a present value returns, and an absent value throws at the call site.
export function must<T>(v: T | null | undefined): T {
  if (v == null) throw new Error("invariant violated: value is absent");
  return v;
}
