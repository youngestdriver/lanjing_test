"use strict";

// CookieCloud crypto and cookie-conversion unit tests. The hardcoded vectors
// below were generated with the official extension's crypto-js implementation
// (ext/utils/functions.ts) and cross-checked against
// `openssl enc -aes-256-cbc -md md5 -salt -S <salt> -p` (legacy KDF) and
// `openssl enc -aes-128-cbc -K <key> -iv 0...0` (fixed). They pin the exact
// interop contract with the browser extension; a failure here means the
// client can no longer exchange data with it.

const assert = require("node:assert/strict");
const { test } = require("node:test");
const crypto = require("node:crypto");
const cookiecloud = require("../lib/cookiecloud");

const V1_UUID = "test-uuid-1234";
const V1_PASSWORD = "test-password-5678";
const V1_PLAIN = '{"cookie_data":{},"local_storage_data":{}}';
// salt 0102030405060708, AES-256-CBC, EVP_BytesToKey(MD5)
const V1_LEGACY = "U2FsdGVkX18BAgMEBQYHCH6Zia7WX/lPiAk9Dhed3vx8TFLyPzqhwlaByt4349lTUfMD9vFVxkq9uyczthmIHA==";
// AES-128-CBC, zero IV, raw base64
const V1_FIXED = "VJYTd1/GVaq27p6vmgE9FJdIPLMEnM7Bc9uRsLjAIjbtPU3Q6fFJAJZ1FSHe3FiV";

const V2_UUID = "uuid-b-998877";
const V2_PASSWORD = "pass-cc-xyz";
const V2_PLAIN = '{"cookie_data":{"test.lanjingweike.com":[{"name":"sessionId","value":"SESS_XYZ_123"}]},"local_storage_data":{}}';
// salt a1b2c3d4e5f60718
const V2_LEGACY = "U2FsdGVkX1+hssPU5fYHGKFCcwVDsFQ8Rtm6kcIhZQOLGfOj3mpiBUTubhhuM30y93XPXCTzCIoKFvZiSfs96BlaptjH00IiQ6xy4LqypQGZv8yFImuQ2fD+A2QsprFrSQOhfWQmiNCnDcuunWYEzzNeEPfXfCoJuq87hTQO9aU=";
const V2_FIXED = "uc0DwkYemk+s/7Ru6tGsJ9n0WuKzQ+0ORnCGd2bKGp07Vp4sbbsX2COq5eO+64oQcFmYAN4k+LVd2C4meAHQ71ipaZwhbqjb1W+0/FhTmMmM++07mflHMHKuoQtx8TTT/HeQvR/TXH2kk2J27IDrRQ==";

test("deriveKey matches the extension's MD5 derivation", () => {
  assert.equal(cookiecloud.deriveKey(V1_UUID, V1_PASSWORD), "ff67775c3432c7dc");
  assert.equal(cookiecloud.deriveKey(V2_UUID, V2_PASSWORD), "c6b0b54daf5c0c37");
});

test("decrypts legacy vectors produced by the official extension", () => {
  assert.equal(cookiecloud.decrypt(V1_LEGACY, V1_UUID, V1_PASSWORD, "legacy"), V1_PLAIN);
  assert.equal(cookiecloud.decrypt(V2_LEGACY, V2_UUID, V2_PASSWORD, "legacy"), V2_PLAIN);
});

test("decrypts fixed vectors produced by the official extension", () => {
  assert.equal(cookiecloud.decrypt(V1_FIXED, V1_UUID, V1_PASSWORD, "aes-128-cbc-fixed"), V1_PLAIN);
  assert.equal(cookiecloud.decrypt(V2_FIXED, V2_UUID, V2_PASSWORD, "aes-128-cbc-fixed"), V2_PLAIN);
});

test("encrypts fixed payloads byte-identically to the extension", () => {
  assert.equal(
    cookiecloud.encrypt(V1_PLAIN, V1_UUID, V1_PASSWORD, "aes-128-cbc-fixed"),
    V1_FIXED,
  );
  assert.equal(
    cookiecloud.encrypt(V2_PLAIN, V2_UUID, V2_PASSWORD, "aes-128-cbc-fixed"),
    V2_FIXED,
  );
});

test("legacy encrypt with a fixed salt reproduces the extension payload", () => {
  // The module's legacyEncrypt uses a random salt; rebuild the vector with a
  // pinned salt to prove the KDF and payload layout match the extension.
  const salt = Buffer.from("0102030405060708", "hex");
  const keyString = cookiecloud.deriveKey(V1_UUID, V1_PASSWORD);
  let previous = Buffer.alloc(0);
  const blocks = [];
  while (blocks.length * 16 < 48) {
    previous = crypto.createHash("md5")
      .update(Buffer.concat([previous, Buffer.from(keyString, "utf8"), salt]))
      .digest();
    blocks.push(previous);
  }
  const derived = Buffer.concat(blocks);
  const cipher = crypto.createCipheriv("aes-256-cbc", derived.subarray(0, 32), derived.subarray(32, 48));
  const ciphertext = Buffer.concat([cipher.update(V1_PLAIN, "utf8"), cipher.final()]);
  const payload = Buffer.concat([Buffer.from("Salted__", "ascii"), salt, ciphertext]).toString("base64");
  assert.equal(payload, V1_LEGACY);
});

test("round-trips both algorithms", () => {
  for (const cryptoType of ["legacy", "aes-128-cbc-fixed"]) {
    assert.equal(
      cookiecloud.decrypt(cookiecloud.encrypt(V2_PLAIN, V2_UUID, V2_PASSWORD, cryptoType),
        V2_UUID, V2_PASSWORD, cryptoType),
      V2_PLAIN,
    );
  }
});

test("decryptAny falls back when the declared crypto_type is wrong", () => {
  // Fixed-IV payload marked "legacy" (observed in the wild: the server stores
  // whatever crypto_type the uploader sent, defaulting to legacy when the
  // field was missing).
  assert.equal(cookiecloud.decryptAny(V1_FIXED, V1_UUID, V1_PASSWORD, "legacy"), V1_PLAIN);
  // Legacy payload marked "aes-128-cbc-fixed".
  assert.equal(cookiecloud.decryptAny(V1_LEGACY, V1_UUID, V1_PASSWORD, "aes-128-cbc-fixed"), V1_PLAIN);
  // Correct declaration still works.
  assert.equal(cookiecloud.decryptAny(V1_FIXED, V1_UUID, V1_PASSWORD, "aes-128-cbc-fixed"), V1_PLAIN);
  // Unknown declared type tries both algorithms, then fails closed.
  assert.equal(cookiecloud.decryptAny(V1_FIXED, V1_UUID, V1_PASSWORD, "future-type"), V1_PLAIN);
  // Wrong password fails both.
  assert.equal(cookiecloud.decryptAny(V1_FIXED, V1_UUID, "wrong-password", "legacy"), null);
});

test("decrypt fails closed instead of returning garbage", () => {
  // Wrong password -> PKCS7 padding failure -> null, not garbage.
  assert.equal(cookiecloud.decrypt(V1_LEGACY, V1_UUID, "wrong-password", "legacy"), null);
  assert.equal(cookiecloud.decrypt(V1_FIXED, V1_UUID, "wrong-password", "aes-128-cbc-fixed"), null);
  // Legacy payload without the Salted__ header is rejected (CryptoJS would
  // silently fall back to a different KDF; we never reproduce that).
  assert.equal(
    cookiecloud.decrypt(crypto.randomBytes(32).toString("base64"), V1_UUID, V1_PASSWORD, "legacy"),
    null,
  );
  // Unknown crypto_type (future extension versions) is rejected.
  assert.equal(cookiecloud.decrypt("x", V1_UUID, V1_PASSWORD, "future-crypto-type"), null);
  // Missing crypto_type defaults to legacy.
  assert.equal(cookiecloud.decrypt(V1_LEGACY, V1_UUID, V1_PASSWORD, undefined), V1_PLAIN);
});

test("jarToCookieData converts the jar to one domain's cookies", () => {
  const data = cookiecloud.jarToCookieData("sessionId=abc123; JSESSIONID=xyz;");
  assert.deepEqual(data, {
    ".lanjingweike.com": [
      { name: "sessionId", value: "abc123", domain: ".lanjingweike.com", path: "/", secure: true, httpOnly: true, sameSite: "lax" },
      { name: "JSESSIONID", value: "xyz", domain: ".lanjingweike.com", path: "/", secure: true, httpOnly: true, sameSite: "lax" },
    ],
  });
  assert.deepEqual(cookiecloud.jarToCookieData(""), { ".lanjingweike.com": [] });
  assert.deepEqual(cookiecloud.jarToCookieData("no-separator"), { ".lanjingweike.com": [] });
});

test("cookieDataToJar imports only lanjingweike domains", () => {
  const mixed = {
    "test.lanjingweike.com": [{ name: "sessionId", value: "S1" }],
    ".lanjingweike.com": [{ name: "other", value: "O1" }],
    "www.baidu.com": [{ name: "BAIDUID", value: "B1" }],
    "not-a-domain": "garbage",
  };
  assert.equal(cookiecloud.cookieDataToJar(mixed), "sessionId=S1; other=O1;");
  assert.equal(cookiecloud.cookieDataToJar(null), "");
  assert.equal(cookiecloud.cookieDataToJar({}), "");
});

test("cookie values containing '=' survive the jar round-trip", () => {
  const jar = cookiecloud.jarToCookieData("k=a=b=c;", "test.lanjingweike.com");
  assert.equal(cookiecloud.cookieDataToJar(jar), "k=a=b=c;");
});

test("mergeCookieData keeps non-lanjingweike domains and replaces ours", () => {
  const remote = {
    "test.lanjingweike.com": [{ name: "sessionId", value: "OLD" }],
    "www.baidu.com": [{ name: "BAIDUID", value: "B1" }],
  };
  const ours = { "test.lanjingweike.com": [{ name: "sessionId", value: "NEW" }] };
  const merged = cookiecloud.mergeCookieData(remote, ours);
  assert.deepEqual(merged, {
    "www.baidu.com": [{ name: "BAIDUID", value: "B1" }],
    "test.lanjingweike.com": [{ name: "sessionId", value: "NEW" }],
  });
  assert.deepEqual(cookiecloud.mergeCookieData(null, ours), ours);
});
