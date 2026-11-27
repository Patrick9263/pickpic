interface ErrorResponse {
  error?: string;
}

/*
 * Carries the HTTP status so a caller can tell "this gallery no longer exists"
 * (404) from a flaky connection without matching on message text.
 */
export class ApiError extends Error {
  readonly status: number;

  constructor(message: string, status: number) {
    super(message);
    this.name = "ApiError";
    this.status = status;
  }
}

export async function getErrorMessage(response: Response): Promise<string> {
  try {
    const body = (await response.json()) as ErrorResponse;

    if (body.error) {
      return body.error;
    }
  } catch {
    // Use the fallback below.
  }

  return `Request failed with status ${response.status}.`;
}

export async function fetchJson<T>(
  input: RequestInfo | URL,
  init?: RequestInit,
): Promise<T> {
  const response = await fetch(input, init);

  if (!response.ok) {
    throw new ApiError(await getErrorMessage(response), response.status);
  }

  return response.json() as Promise<T>;
}
