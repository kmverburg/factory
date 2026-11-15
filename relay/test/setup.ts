import { timingSafeEqual } from "node:crypto";

// Cloudflare Workers add `crypto.subtle.timingSafeEqual`; Node doesn't. Provide it so the
// relay's real signature check runs unchanged in tests.
const subtle = crypto.subtle as any;
if (!subtle.timingSafeEqual) {
  subtle.timingSafeEqual = (a: ArrayBufferView, b: ArrayBufferView) =>
    timingSafeEqual(
      new Uint8Array(a.buffer, a.byteOffset, a.byteLength),
      new Uint8Array(b.buffer, b.byteOffset, b.byteLength),
    );
}
