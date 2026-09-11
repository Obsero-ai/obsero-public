FROM node:22-alpine
WORKDIR /app
COPY server.mjs ./
COPY public ./public
ENV PORT=8080
EXPOSE 8080
CMD ["node", "server.mjs"]
