export function cartUrl(id: string, version = 1): string {
  return version === 2 ? `/v2/carts/${id}` : `/carts/${id}`;
}
