# vLEI-Gate KYB Portal (Next.js, standalone output). Build context = frontend/.
# NEXT_PUBLIC_* values are baked in at build time: public contract addresses come from .env.local,
# the backend URL from the build arg below (it overrides .env.local).
FROM node:22-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
ARG NEXT_PUBLIC_BACKEND_URL
ARG NEXT_PUBLIC_COURNOT_REFRESH=false
ENV NEXT_PUBLIC_BACKEND_URL=$NEXT_PUBLIC_BACKEND_URL \
    NEXT_PUBLIC_COURNOT_REFRESH=$NEXT_PUBLIC_COURNOT_REFRESH \
    NEXT_TELEMETRY_DISABLED=1
RUN test -n "$NEXT_PUBLIC_BACKEND_URL" && npm run build

FROM node:22-slim
WORKDIR /app
ENV NODE_ENV=production NEXT_TELEMETRY_DISABLED=1 PORT=8080 HOSTNAME=0.0.0.0
COPY --from=build /app/.next/standalone ./
COPY --from=build /app/.next/static ./.next/static
USER node
EXPOSE 8080
CMD ["node", "server.js"]
