export default {
  async fetch(request, env, ctx) {
    const response = await fetch(request);

    // Error codes that suggest the Tunnel or Docker container is down
    const errorCodes = [404, 502, 503, 504, 530];

    if (errorCodes.includes(response.status)) {
      // Look for the Radicale signature
      const isRadicale = response.headers.has("WWW-Authenticate") || 
                         response.headers.get("server")?.toLowerCase().includes("radicale");

      // If it's a generic error NOT from Radicale, intercept it
      if (!isRadicale) {
        return new Response("Radicale Server Unreachable: Tunnel Connection Interrupted", {
          status: 503,
          statusText: "Service Unavailable",
          headers: {
            "Content-Type": "text/plain",
            "Retry-After": "300",
            "Cache-Control": "no-store",
            // Custom header to confirm this Worker is active
            "X-Worker-Status": "Intercepted-by-Radicale-Fixer"
          }
        });
      }
    }

    // Add the header even to successful requests so you know the Worker is watching
    const newHeaders = new Headers(response.headers);
    newHeaders.set("X-Worker-Status", "Proxy-Active");

    return new Response(response.body, {
      status: response.status,
      statusText: response.statusText,
      headers: newHeaders
    });
  }
};
