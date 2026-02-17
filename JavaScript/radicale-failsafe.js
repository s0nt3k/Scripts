export default {
  async fetch(request, env, ctx) {
    const response = await fetch(request);

    // Added 530 to the list to catch Cloudflare Tunnel 'Origin DNS' errors
    const errorCodes = [404, 502, 503, 504, 530];

    if (errorCodes.includes(response.status)) {
      // Check if the response actually came from Radicale
      const isRadicale = response.headers.has("WWW-Authenticate") || 
                         response.headers.get("server")?.toLowerCase().includes("radicale");

      if (!isRadicale) {
        return new Response("Radicale Server Unreachable: Tunnel Connection Interrupted", {
          status: 503,
          statusText: "Service Unavailable",
          headers: {
            "Content-Type": "text/plain",
            "Retry-After": "300",
            "Cache-Control": "no-store"
          }
        });
      }
    }

    return response;
  }
};
