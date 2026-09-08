export type AccessToken = string;

export function isAccessToken(value: unknown): value is AccessToken {
  return typeof value === "string";
}
