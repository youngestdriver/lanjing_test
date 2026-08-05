"use strict";

// CookieCloud client: encryption and cookie conversions compatible with the
// official browser extension (github.com/easychen/CookieCloud, ext/utils/
// functions.ts). The CookieCloud server is a dumb encrypted store — it never
// sees the plaintext — so any client that speaks these two algorithms can
// interoperate with the extension's uploaded blob.
//
//   the_key = MD5(`${uuid}-${password}`).hex.slice(0, 16)   // 16-char string
//
//   legacy ("legacy", extension default):
//     CryptoJS AES with a string passphrase -> OpenSSL EVP_BytesToKey (MD5)
//     deriving an AES-256-CBC key+iv; random 8-byte salt; PKCS7; payload is
//     base64("Salted__" + salt + ciphertext).
//
//   fixed ("aes-128-cbc-fixed"):
//     key = UTF-8 bytes of the_key (16 bytes, AES-128), IV = 16 zero bytes,
//     AES-128-CBC PKCS7; payload is raw base64 ciphertext.
//
// We always push with "aes-128-cbc-fixed" and decrypt either type. Decryption
// fails closed: a missing "Salted__" header, an unknown crypto_type or a bad
// password (PKCS7 padding error) raises instead of returning garbage.

const crypto = require("crypto");

const SALTED_PREFIX = Buffer.from("Salted__", "ascii");
const PUSH_DOMAIN = "test.lanjingweike.com";
const LANJING_DOMAIN_MARKER = "lanjingweike.com";
const REQUEST_TIMEOUT = 10000;

async function fetchWithTimeout(url, init = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT);
  try { return await fetch(url, { ...init, signal: controller.signal }); }
  finally { clearTimeout(timer); }
}

// POST {server}/update — overwrite the uuid's encrypted blob.
async function push(server, uuid, encrypted, cryptoType) {
  const url = `${String(server).replace(/\/+$/, "")}/update`;
  const response = await fetchWithTimeout(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ uuid, encrypted, crypto_type: cryptoType }),
  });
  if (!response.ok) throw new Error(`cookiecloud: upload failed with status ${response.status}`);
  const data = await response.json().catch(() => ({}));
  if (data.action !== "done") throw new Error("cookiecloud: upload was not acknowledged");
}

// GET {server}/get/{uuid} — fetch the encrypted blob. Returns null when the
// blob does not exist yet (404): callers treat that as an empty cloud, e.g.
// first-time setup where the push creates the blob. Other failures throw.
async function pull(server, uuid) {
  const url = `${String(server).replace(/\/+$/, "")}/get/${encodeURIComponent(uuid)}`;
  const response = await fetchWithTimeout(url);
  if (response.status === 404) return null;
  if (!response.ok) throw new Error(`cookiecloud: download failed with status ${response.status}`);
  const data = await response.json();
  if (!data || typeof data.encrypted !== "string") {
    throw new Error("cookiecloud: malformed download response");
  }
  return {
    encrypted: data.encrypted,
    crypto_type: typeof data.crypto_type === "string" ? data.crypto_type : "legacy",
  };
}

function md5Hex(input) {
  return crypto.createHash("md5").update(input).digest("hex");
}

// The 16-character key string both algorithms derive from uuid + password.
function deriveKey(uuid, password) {
  return md5Hex(`${uuid}-${password}`).slice(0, 16);
}

// OpenSSL EVP_BytesToKey with MD5: D1=MD5(pass+salt), D2=MD5(D1+pass+salt),
// D3=MD5(D2+pass+salt); key = D1||D2 (32 B), iv = D3 (16 B).
function evpBytesToKey(passphrase, salt) {
  const pass = Buffer.from(passphrase, "utf8");
  let previous = Buffer.alloc(0);
  const material = [];
  while (material.length * 16 < 48) {
    // Buffer.concat only — a `+` here would string-coerce the buffers.
    previous = md5Buffer(Buffer.concat([previous, pass, salt]));
    material.push(previous);
  }
  const derived = Buffer.concat(material);
  return {
    key: derived.subarray(0, 32),
    iv: derived.subarray(32, 48),
  };
}

function md5Buffer(data) {
  return crypto.createHash("md5").update(data).digest();
}

function legacyEncrypt(data, keyString, salt = crypto.randomBytes(8)) {
  const { key, iv } = evpBytesToKey(keyString, salt);
  const cipher = crypto.createCipheriv("aes-256-cbc", key, iv);
  const ciphertext = Buffer.concat([cipher.update(data, "utf8"), cipher.final()]);
  return Buffer.concat([SALTED_PREFIX, salt, ciphertext]).toString("base64");
}

function legacyDecrypt(encrypted, keyString) {
  const payload = Buffer.from(String(encrypted), "base64");
  if (payload.length < SALTED_PREFIX.length + 8
    || !payload.subarray(0, SALTED_PREFIX.length).equals(SALTED_PREFIX)) {
    throw new Error("cookiecloud: legacy payload is missing the Salted__ header");
  }
  const salt = payload.subarray(SALTED_PREFIX.length, SALTED_PREFIX.length + 8);
  const ciphertext = payload.subarray(SALTED_PREFIX.length + 8);
  const { key, iv } = evpBytesToKey(keyString, salt);
  const decipher = crypto.createDecipheriv("aes-256-cbc", key, iv);
  // A wrong password surfaces here as a PKCS7 padding error.
  return Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString("utf8");
}

function fixedEncrypt(data, keyString) {
  const key = Buffer.from(keyString, "utf8");
  const cipher = crypto.createCipheriv("aes-128-cbc", key, Buffer.alloc(16));
  return Buffer.concat([cipher.update(data, "utf8"), cipher.final()]).toString("base64");
}

function fixedDecrypt(encrypted, keyString) {
  const key = Buffer.from(keyString, "utf8");
  const decipher = crypto.createDecipheriv("aes-128-cbc", key, Buffer.alloc(16));
  return Buffer.concat([decipher.update(Buffer.from(String(encrypted), "base64")), decipher.final()])
    .toString("utf8");
}

function encrypt(data, uuid, password, cryptoType = "aes-128-cbc-fixed") {
  const keyString = deriveKey(uuid, password);
  if (cryptoType === "aes-128-cbc-fixed") return fixedEncrypt(data, keyString);
  if (cryptoType === "legacy") return legacyEncrypt(data, keyString);
  throw new Error(`cookiecloud: unsupported crypto_type ${cryptoType}`);
}

// Returns the decrypted plaintext string, or null when the payload cannot be
// decrypted (wrong password, unknown crypto_type, malformed payload). A
// missing crypto_type defaults to "legacy" (the extension's default writer).
function decrypt(encrypted, uuid, password, cryptoType = "legacy") {
  try {
    const keyString = deriveKey(uuid, password);
    if (cryptoType === "aes-128-cbc-fixed") return fixedDecrypt(encrypted, keyString);
    if (cryptoType === "legacy") return legacyDecrypt(encrypted, keyString);
    throw new Error(`cookiecloud: unsupported crypto_type ${cryptoType}`);
  } catch {
    return null;
  }
}

// Decrypt trying the declared crypto_type first, then the other algorithm.
// The CookieCloud server stores whatever crypto_type the last uploader sent
// (defaulting to "legacy" when the field is missing), which is not always the
// algorithm actually used — observed in the wild with a fixed-IV payload
// marked "legacy". Unknown declared types fail closed after the fallback.
function decryptAny(encrypted, uuid, password, cryptoType = "legacy") {
  const attempts = cryptoType === "aes-128-cbc-fixed"
    ? ["aes-128-cbc-fixed", "legacy"]
    : ["legacy", "aes-128-cbc-fixed"];
  for (const type of attempts) {
    const plaintext = decrypt(encrypted, uuid, password, type);
    if (plaintext !== null) return plaintext;
  }
  return null;
}

// Jar string ("a=1; b=2;") -> CookieCloud cookie_data for one domain.
function jarToCookieData(jar, domain = PUSH_DOMAIN) {
  const cookies = [];
  for (const part of String(jar || "").split(";")) {
    const pair = part.trim();
    const separator = pair.indexOf("=");
    if (separator <= 0) continue;
    cookies.push({
      name: pair.slice(0, separator),
      value: pair.slice(separator + 1),
      domain,
      path: "/",
      secure: true,
      httpOnly: true,
      sameSite: "lax",
    });
  }
  return { [domain]: cookies };
}

// CookieCloud cookie_data -> jar string. Only lanjingweike cookies are
// imported; everything else (from an extension upload) is ignored.
function cookieDataToJar(cookieData) {
  if (!cookieData || typeof cookieData !== "object") return "";
  const jar = [];
  for (const [domain, cookies] of Object.entries(cookieData)) {
    if (!String(domain).includes(LANJING_DOMAIN_MARKER) || !Array.isArray(cookies)) continue;
    for (const cookie of cookies) {
      if (!cookie || typeof cookie.name !== "string" || typeof cookie.value !== "string") continue;
      jar.push(`${cookie.name}=${cookie.value}`);
    }
  }
  return jar.length ? `${jar.join("; ")};` : "";
}

// Merge our push payload into the remote blob: every non-lanjingweike domain
// from the remote is kept, our lanjingweike entry replaces the remote's.
function mergeCookieData(remote, ours) {
  const merged = {};
  if (remote && typeof remote === "object") {
    for (const [domain, cookies] of Object.entries(remote)) {
      if (!String(domain).includes(LANJING_DOMAIN_MARKER)) merged[domain] = cookies;
    }
  }
  return { ...merged, ...ours };
}

module.exports = {
  deriveKey,
  encrypt,
  decrypt,
  decryptAny,
  jarToCookieData,
  cookieDataToJar,
  mergeCookieData,
  push,
  pull,
  PUSH_DOMAIN,
  LANJING_DOMAIN_MARKER,
};
