FROM node:20-slim

WORKDIR /app

# Install Tailscale
RUN apt-get update && apt-get install -y curl && \
    curl -fsSL https://tailscale.com/install.sh | sh && \
    apt-get remove -y curl && apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/*

# Create tailscale runtime dirs
RUN mkdir -p /var/run/tailscale /var/lib/tailscale

# Install production dependencies (cached layer -- only re-runs when package files change)
COPY server/package*.json ./server/
RUN cd server && npm ci --omit=dev

# Copy application sources
COPY server/ ./server/
COPY public/ ./public/
COPY docker/prod/entrypoint.sh ./entrypoint.sh

ENV PORT=8081 \
    NODE_ENV=production

EXPOSE 8081

ENTRYPOINT ["./entrypoint.sh"]
