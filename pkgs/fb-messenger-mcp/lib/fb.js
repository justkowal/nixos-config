export function getToken() {
  return (
    process.env.MESSENGER_PLATFORM_API_API_KEY ||
    process.env.FB_PAGE_ACCESS_TOKEN ||
    process.env.PAGE_ACCESS_TOKEN ||
    ""
  );
}

export function getPageId(argPageId) {
  return argPageId || process.env.FB_PAGE_ID || process.env.PAGE_ID || "me";
}
