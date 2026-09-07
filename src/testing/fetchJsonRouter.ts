export type FetchJsonRouteMethod = "GET" | "POST" | "PUT" | "DELETE" | "PATCH";

export interface FetchJsonCall {
  method: FetchJsonRouteMethod;
  url: string;
  init: RequestInit | undefined;
  body: unknown;
}

export type FetchJsonRouteResponse<T> =
  T | ((call: FetchJsonCall) => T | Promise<T>);

interface FetchJsonRoute {
  method: FetchJsonRouteMethod;
  pattern: RegExp;
  respond: FetchJsonRouteResponse<unknown>;
}

function parseJsonBody(init: RequestInit | undefined): unknown {
  if (typeof init?.body !== "string") {
    return undefined;
  }

  try {
    return JSON.parse(init.body);
  } catch {
    return init.body;
  }
}

export interface FetchJsonRouter {
  readonly calls: FetchJsonCall[];
  on<T>(
    method: FetchJsonRouteMethod,
    urlPattern: RegExp,
    respond: FetchJsonRouteResponse<T>,
  ): void;
  get<T>(urlPattern: RegExp, respond: FetchJsonRouteResponse<T>): void;
  post<T>(urlPattern: RegExp, respond: FetchJsonRouteResponse<T>): void;
  put<T>(urlPattern: RegExp, respond: FetchJsonRouteResponse<T>): void;
  delete<T>(urlPattern: RegExp, respond: FetchJsonRouteResponse<T>): void;
  fetchJson<T>(input: RequestInfo | URL, init?: RequestInit): Promise<T>;
}

/*
 * Replaces the per-test `url.includes(...)` / `init?.method === ...` chains
 * that hand-rolled fetchJson mocks needed (see GalleryPage.heart.test.tsx).
 * An unmatched request throws instead of resolving to `undefined`, so a
 * routing mistake fails at the request site rather than surfacing as a
 * confusing render assertion several lines later.
 */
export function createFetchJsonRouter(): FetchJsonRouter {
  const routes: FetchJsonRoute[] = [];
  const calls: FetchJsonCall[] = [];

  function on<T>(
    method: FetchJsonRouteMethod,
    urlPattern: RegExp,
    respond: FetchJsonRouteResponse<T>,
  ): void {
    routes.push({
      method,
      pattern: urlPattern,
      respond: respond as FetchJsonRouteResponse<unknown>,
    });
  }

  async function fetchJson<T>(
    input: RequestInfo | URL,
    init?: RequestInit,
  ): Promise<T> {
    const method = (
      init?.method ?? "GET"
    ).toUpperCase() as FetchJsonRouteMethod;
    const url = String(input);

    const call: FetchJsonCall = {
      method,
      url,
      init,
      body: parseJsonBody(init),
    };

    calls.push(call);

    const route = routes.find(
      (candidate) => candidate.method === method && candidate.pattern.test(url),
    );

    if (!route) {
      const registered = routes
        .map((candidate) => `${candidate.method} ${candidate.pattern}`)
        .join(", ");

      throw new Error(
        `No fetchJson route registered for ${method} ${url}. ` +
          `Registered routes: ${registered || "(none)"}`,
      );
    }

    const { respond } = route;

    if (typeof respond === "function") {
      return (await (respond as (call: FetchJsonCall) => T | Promise<T>)(
        call,
      )) as T;
    }

    return respond as T;
  }

  return {
    calls,
    on,
    get: (urlPattern, respond) => on("GET", urlPattern, respond),
    post: (urlPattern, respond) => on("POST", urlPattern, respond),
    put: (urlPattern, respond) => on("PUT", urlPattern, respond),
    delete: (urlPattern, respond) => on("DELETE", urlPattern, respond),
    fetchJson,
  };
}
