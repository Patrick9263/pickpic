import {
  createExecutionContext,
  env,
  waitOnExecutionContext,
} from "cloudflare:test";
import { expect } from "vitest";
import worker from "./index.ts";

/*
 * Shared driver for every worker/*.workers.test.ts route file (see #167).
 * gallery.workers.test.ts proved the shape: createExecutionContext + a
 * typed IncomingRequest + waitOnExecutionContext. This module just makes
 * that shape reusable instead of re-implemented per file.
 *
 * An exported handler is typed against an *incoming* request, which carries
 * a populated `cf` object a plain `new Request()` does not. This
 * instantiation expression is Cloudflare's documented way to get a
 * constructor with that signature; it is a type-level narrowing only, with
 * no runtime effect.
 */
const IncomingRequest = Request<unknown, IncomingRequestCfProperties>;

/*
 * A localhost origin takes the local-development branch in
 * requireAdminAccess (worker/access.ts:154) -- no JWKS, no Access setup --
 * and is exempt from the same-origin/CSRF check on state-changing requests
 * (worker/auth.ts:288-296), so admin PUT/POST/DELETE need no Origin header
 * here. See #167's boundary comment for why this is the intended way in.
 */
const ADMIN_ORIGIN = "http://localhost";

const GALLERY_ORIGIN = "https://pickpic.photos";

export interface RequestOptions {
  json?: unknown;
  formData?: FormData;
  headers?: HeadersInit;
}

export interface DrivenResponse<T = unknown> {
  response: Response;
  status: number;
  body: T;
}

async function driveRequest<T>(
  origin: string,
  method: string,
  path: string,
  options: RequestOptions = {},
): Promise<DrivenResponse<T>> {
  if (options.json !== undefined && options.formData !== undefined) {
    throw new Error("Pass at most one of json or formData.");
  }

  const headers = new Headers(options.headers);
  let body: BodyInit | undefined;

  if (options.json !== undefined) {
    headers.set("Content-Type", "application/json");
    body = JSON.stringify(options.json);
  } else if (options.formData) {
    /* No Content-Type here -- FormData needs to set its own boundary. */
    body = options.formData;
  }

  const ctx = createExecutionContext();
  const response = await worker.fetch(
    new IncomingRequest(`${origin}${path}`, { method, headers, body }),
    env,
    ctx,
  );

  await waitOnExecutionContext(ctx);

  /*
   * Every response in the admin/gallery API surface this harness targets is
   * JSON (jsonResponse / Response.json). The catch only guards against a
   * future route this harness reaches that isn't.
   */
  const parsedBody = (await response
    .clone()
    .json()
    .catch(() => null)) as T;

  return { response, status: response.status, body: parsedBody };
}

export function adminRequest<T = unknown>(
  method: string,
  path: string,
  options?: RequestOptions,
): Promise<DrivenResponse<T>> {
  return driveRequest<T>(ADMIN_ORIGIN, method, path, options);
}

export function galleryRequest<T = unknown>(
  method: string,
  path: string,
  options?: RequestOptions,
): Promise<DrivenResponse<T>> {
  return driveRequest<T>(GALLERY_ORIGIN, method, path, options);
}

/*
 * The worker returns this shape -- {error} at a given status -- from nearly
 * every validation and not-found branch. Pass `error` to assert the exact
 * message, or omit it to just pin the status and shape.
 */
export function expectError(
  result: DrivenResponse<unknown>,
  status: number,
  error?: string,
): void {
  expect(result.status).toBe(status);

  if (error !== undefined) {
    expect(result.body).toEqual({ error });
  } else {
    expect(result.body).toMatchObject({ error: expect.any(String) });
  }
}

export function expectMethodNotAllowed(result: DrivenResponse<unknown>): void {
  expectError(result, 405, "Method not allowed.");
}
