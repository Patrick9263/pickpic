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

  /*
   * A raw body, for the upload routes that take bytes rather than JSON or a
   * form. The caller sets its own Content-Type through `headers`, because
   * those routes dispatch on it.
   */
  body?: BodyInit;

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
  const bodyCount = [options.json, options.formData, options.body].filter(
    (candidate) => candidate !== undefined,
  ).length;

  if (bodyCount > 1) {
    throw new Error("Pass at most one of json, formData or body.");
  }

  const headers = new Headers(options.headers);
  let body: BodyInit | undefined;

  if (options.json !== undefined) {
    headers.set("Content-Type", "application/json");
    body = JSON.stringify(options.json);
  } else if (options.formData) {
    /* No Content-Type here -- FormData needs to set its own boundary. */
    body = options.formData;
  } else if (options.body !== undefined) {
    body = options.body;
  }

  const ctx = createExecutionContext();
  const response = await worker.fetch(
    new IncomingRequest(`${origin}${path}`, { method, headers, body }),
    env,
    ctx,
  );

  await waitOnExecutionContext(ctx);

  /*
   * Nearly every response in the admin/gallery API surface this harness
   * targets is JSON (jsonResponse / Response.json), and the error shapes the
   * assertions read certainly are. The RAW download route is the exception --
   * it streams bytes -- and workerd logs a loud warning when a body is decoded
   * as text against an octet-stream Content-Type, so the type is checked
   * rather than parsed-and-caught. Callers reading a binary response use
   * `result.response` directly.
   */
  const isJson = response.headers
    .get("Content-Type")
    ?.toLowerCase()
    .includes("json");

  const parsedBody = (
    isJson
      ? await response
          .clone()
          .json()
          .catch(() => null)
      : null
  ) as T;

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
