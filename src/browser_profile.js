// Mobile browser profile — injected before page scripts in scrape mode.
// Emulates a Pixel 5 (Android 12 / Chrome 120) to pass basic UA and
// fingerprinting checks. Does NOT defeat Cloudflare/Akamai JS challenges.
(function () {
  "use strict";

  const profile = {
    userAgent:
      "Mozilla/5.0 (Linux; Android 12; Pixel 5) " +
      "AppleWebKit/537.36 (KHTML, like Gecko) " +
      "Chrome/120.0.0.0 Mobile Safari/537.36",
    platform: "Linux armv8l",
    language: "en-US",
    languages: ["en-US", "en"],
    hardwareConcurrency: 8,
    deviceMemory: 4,
    maxTouchPoints: 5,
    screen: { width: 393, height: 851, availWidth: 393, availHeight: 851, colorDepth: 24, pixelDepth: 24 },
    devicePixelRatio: 2.75,
  };

  function def(obj, prop, value) {
    Object.defineProperty(obj, prop, { get: () => value, configurable: true });
  }

  // Ensure globals that may not exist in a headless runtime are present
  if (typeof screen === "undefined")      window.screen      = {};
  if (typeof performance === "undefined") window.performance = {};

  // Navigator identity
  def(navigator, "userAgent", profile.userAgent);
  def(navigator, "platform", profile.platform);
  def(navigator, "language", profile.language);
  def(navigator, "languages", profile.languages);
  def(navigator, "hardwareConcurrency", profile.hardwareConcurrency);
  def(navigator, "deviceMemory", profile.deviceMemory);
  def(navigator, "maxTouchPoints", profile.maxTouchPoints);
  def(navigator, "plugins", []);
  def(navigator, "mimeTypes", []);

  // Remove automation marker
  try { delete navigator.webdriver; } catch (_) {}

  // Permissions stub
  if (!navigator.permissions)
    navigator.permissions = { query: async () => ({ state: "prompt", onchange: null }) };

  // Media devices stub
  navigator.mediaDevices = { enumerateDevices: async () => [] };

  // Screen dimensions (Pixel 5)
  def(screen, "width",       profile.screen.width);
  def(screen, "height",      profile.screen.height);
  def(screen, "availWidth",  profile.screen.availWidth);
  def(screen, "availHeight", profile.screen.availHeight);
  def(screen, "colorDepth",  profile.screen.colorDepth);
  def(screen, "pixelDepth",  profile.screen.pixelDepth);

  // Window dimensions
  def(window, "devicePixelRatio", profile.devicePixelRatio);
  def(window, "innerWidth",  393);
  def(window, "innerHeight", 760);
  def(window, "outerWidth",  393);
  def(window, "outerHeight", 851);

  // Remove WebGL (not available in headless compositor)
  try { delete window.WebGLRenderingContext;  } catch (_) {}
  try { delete window.WebGL2RenderingContext; } catch (_) {}

  // Redirect canvas.getContext("webgl") → null
  if (typeof HTMLCanvasElement !== "undefined") {
    const _orig = HTMLCanvasElement.prototype.getContext;
    HTMLCanvasElement.prototype.getContext = function (type, ...args) {
      if (type === "webgl" || type === "webgl2") return null;
      return _orig.call(this, type, ...args);
    };
  }

  // Touch event presence
  def(window, "ontouchstart", null);
  def(window, "ontouchmove",  null);
  def(window, "ontouchend",   null);

  // Chrome runtime stub
  if (!window.chrome) window.chrome = { runtime: {} };

  // Timing jitter to defeat timing-based fingerprinting (best-effort — read-only in some runtimes)
  try {
    if (typeof performance !== "undefined" && performance.now) {
      const _orig = performance.now.bind(performance);
      Object.defineProperty(performance, "now", {
        value: () => _orig() + (Math.random() - 0.5) * 0.1,
        configurable: true, writable: true,
      });
    }
  } catch (_) {}
})();
