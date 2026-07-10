interface CreateEventBody {
  title?: unknown;
}

interface EventRecord {
  id: string;
  title: string;
  shareToken: string;
  status: string;
  createdAt: string;
  updatedAt: string;
}

function jsonResponse(data: unknown, status = 200): Response {
  return Response.json(data, {
    status,
    headers: {
      "Cache-Control": "no-store",
    },
  });
}

function generateShareToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(16));

  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join(
    "",
  );
}

async function createEvent(request: Request, env: Env): Promise<Response> {
  let body: CreateEventBody;

  try {
    body = await request.json<CreateEventBody>();
  } catch {
    return jsonResponse({ error: "The request body must be valid JSON." }, 400);
  }

  if (typeof body.title !== "string") {
    return jsonResponse({ error: "An event title is required." }, 400);
  }

  const title = body.title.trim();

  if (title.length === 0 || title.length > 120) {
    return jsonResponse(
      { error: "The event title must be between 1 and 120 characters." },
      400,
    );
  }

  const event: EventRecord = {
    id: crypto.randomUUID(),
    title,
    shareToken: generateShareToken(),
    status: "draft",
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
  };

  await env.DB.prepare(
    `
      INSERT INTO events (
        id,
        title,
        share_token,
        status,
        created_at,
        updated_at
      )
      VALUES (?, ?, ?, ?, ?, ?)
    `,
  )
    .bind(
      event.id,
      event.title,
      event.shareToken,
      event.status,
      event.createdAt,
      event.updatedAt,
    )
    .run();

  return jsonResponse({ event }, 201);
}

async function listEvents(env: Env): Promise<Response> {
  const result = await env.DB.prepare(
    `
      SELECT
        id,
        title,
        share_token AS shareToken,
        status,
        created_at AS createdAt,
        updated_at AS updatedAt
      FROM events
      ORDER BY created_at DESC
    `,
  ).all<EventRecord>();

  return jsonResponse({
    events: result.results,
  });
}

export default {
  async fetch(request, env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/api/events") {
      if (request.method === "POST") {
        return createEvent(request, env);
      }

      if (request.method === "GET") {
        return listEvents(env);
      }

      return jsonResponse({ error: "Method not allowed." }, 405);
    }

    if (url.pathname.startsWith("/api/")) {
      return jsonResponse({ error: "API route not found." }, 404);
    }

    return new Response(null, { status: 404 });
  },
} satisfies ExportedHandler<Env>;
