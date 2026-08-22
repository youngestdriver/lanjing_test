"use strict";

// Tests for stripTrailingFiller — the web port of iOS RichHTMLContent /
// Android HtmlRenderer. Upstream rich-text editors append empty filler blocks
// (<p><br/></p>, <p>&nbsp;</p>, stray <br>, &nbsp;/whitespace runs) after the
// visible question content; browsers render them as full blank lines, the
// varying gap between a stem and its options.

const assert = require("node:assert/strict");
const { test } = require("node:test");
const { stripTrailingFiller } = require("../lib/clean-html");

const style = "box-sizing: border-box; font-family: -apple-system; padding: 0px; line-height: 2rem; color: rgb(60, 70, 79); font-size: 16px";

test("strips the real trailing empty paragraph sample", () => {
  const text = `<p style="${style}">这段文字意在强调（ ）。</p>`;
  assert.equal(stripTrailingFiller(text + "<p><br/></p>"), text);
});

test("strips consecutive empty paragraphs", () => {
  assert.equal(stripTrailingFiller("<p>甲</p><p><br/></p><p>&nbsp;</p>"), "<p>甲</p>");
});

test("strips trailing break tags", () => {
  assert.equal(stripTrailingFiller("<p>甲</p><br><br/>"), "<p>甲</p>");
});

test("strips trailing nbsp runs", () => {
  assert.equal(stripTrailingFiller("<p>甲</p>&nbsp;&nbsp;"), "<p>甲</p>");
});

test("strips trailing whitespace", () => {
  assert.equal(stripTrailingFiller("<p>甲</p>\n \t"), "<p>甲</p>");
});

test("strips empty paragraph with nested empty span", () => {
  assert.equal(stripTrailingFiller("<p>甲</p><p><span>&nbsp;</span></p>"), "<p>甲</p>");
});

test("strips empty div block", () => {
  assert.equal(stripTrailingFiller("<p>甲</p><div><br/></div>"), "<p>甲</p>");
});

test("strips uppercase filler tags", () => {
  assert.equal(stripTrailingFiller("<P>甲</P><P><BR/></P>"), "<P>甲</P>");
});

test("keeps a trailing br inside a non-empty paragraph", () => {
  assert.equal(stripTrailingFiller("<p>甲<br>乙</p>"), "<p>甲<br>乙</p>");
});

test("keeps a trailing image", () => {
  assert.equal(stripTrailingFiller('<p>甲</p><img src="/x.png">'), '<p>甲</p><img src="/x.png">');
});

test("keeps an image inside the trailing paragraph", () => {
  const html = '<p>看图</p><p><img src="/x.png"></p>';
  assert.equal(stripTrailingFiller(html), html);
});

test("keeps a table inside the trailing block", () => {
  const html = "<p>甲</p><table><tr><td>乙</td></tr></table>";
  assert.equal(stripTrailingFiller(html), html);
});

test("keeps a hr inside the trailing paragraph", () => {
  const html = "<p>甲</p><p><hr></p>";
  assert.equal(stripTrailingFiller(html), html);
});

test("keeps interior blank paragraphs", () => {
  assert.equal(stripTrailingFiller("<p>甲</p><p><br/></p><p>乙</p>"), "<p>甲</p><p><br/></p><p>乙</p>");
});

test("keeps the answer blank inside the paragraph", () => {
  assert.equal(stripTrailingFiller("<p>甲（&nbsp;&nbsp;）。</p>"), "<p>甲（&nbsp;&nbsp;）。</p>");
});

test("filler-only document empties", () => {
  assert.equal(stripTrailingFiller("<p><br/></p><p>&nbsp;</p>"), "");
});

test("clean input is unchanged", () => {
  assert.equal(stripTrailingFiller("<p>甲</p>"), "<p>甲</p>");
});
