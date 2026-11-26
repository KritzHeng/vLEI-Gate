/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  // Self-contained server for the Docker image (frontend/Dockerfile); `npm run dev` is unaffected.
  output: "standalone",
};
export default nextConfig;
