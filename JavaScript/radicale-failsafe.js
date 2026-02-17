export default {
  async fetch(request, env, ctx) {
    // 1. Forward the request to your tunnel origin
    const response = await fetch(request);

    // 2. Check if the response is a 404
    // Cloudflare Tunnels often return 404 when the connector is offline
    if (response.status === 404) {
      return new Response("Tunnel Interrupted: Origin Unreachable", {
        status: 503,
        statusText: "Service Unavailable",
        headers: {
          ...response.headers,
          "Retry-After": "300", // Suggests the client retries in 5 minutes
          "Content-Type": "text/plain"
        }
      });
    }

    // 3. If it's any other status (200, 401, etc.), return it as is
    return response;
  }
};
