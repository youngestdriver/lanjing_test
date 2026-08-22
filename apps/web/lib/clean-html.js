"use strict";

// stripTrailingFiller — the web port of iOS RichHTMLContent.stripTrailingFiller
// / Android HtmlRenderer.stripTrailingFiller.
//
// The upstream rich-text editors append empty filler blocks after the visible
// content (<p><br/></p>, <p>&nbsp;</p>, stray <br>, &nbsp;/whitespace runs) and
// the browser renders each as a full blank line — the varying gap between a
// question's stem and its options, and inside the analysis. Only the tail is
// stripped: interior blank paragraphs, a trailing <br> inside a paragraph that
// carries words, the answer blanks inside the question text (（　　）), and
// blocks that contain images/tables/media (real content) are preserved.

// Tags that render actual content — a block holding one is never filler.
const VISUAL_TAG = /<(?:img|picture|svg|canvas|iframe|embed|object|video|audio|table|math|input|textarea|select|hr|form)\b/i;

const TRAILING_WS = /(?:&nbsp;|\s)+$/i; // JS \s (unlike Java) includes NBSP
const TRAILING_BR = /<br\s*\/?>(?:&nbsp;|\s)*$/i;

function lastIndexOfCI(haystack, needle) {
  return haystack.toUpperCase().lastIndexOf(needle.toUpperCase());
}

/** Drops the trailing <p>…</p> / <div>…</div> block whose rendered text is
 *  empty (whitespace / &nbsp; / filler tags only); null when the tail carries
 *  content or the structure is malformed. */
function removeTrailingEmptyBlock(html) {
  const pClose = lastIndexOfCI(html, "</p>");
  const divClose = lastIndexOfCI(html, "</div>");
  const useDiv = divClose >= 0 && (pClose < 0 || divClose > pClose);
  if (pClose < 0 && divClose < 0) return null;
  const closePos = useDiv ? divClose : pClose;
  const tag = useDiv ? "div" : "p";
  // Latest open tag of this kind before the close; the lookahead keeps
  // </p>, <pre>, <picture> etc. from matching.
  const opens = [...html.matchAll(new RegExp(`<${tag}(?=[\\s>])`, "gi"))];
  const open = opens.filter((match) => match.index < closePos).at(-1);
  if (!open || open.index == null) return null;
  // The open tag must actually terminate before the close tag.
  const gt = html.indexOf(">", open.index + 1 + tag.length);
  if (gt < 0 || gt > closePos) return null;
  const content = html.slice(gt + 1, closePos);
  if (VISUAL_TAG.test(content)) return null;
  const text = content
    .replace(/<[^>]+>/g, "")
    .replace(/&nbsp;/g, " ")
    .replace(/&#160;/g, " ")
    .trim();
  if (text !== "") return null;
  return html.slice(0, open.index) + html.slice(closePos + tag.length + 3);
}

function stripTrailingFiller(html) {
  let result = html;
  while (true) {
    const before = result;
    result = result.replace(TRAILING_WS, "").replace(TRAILING_BR, "");
    const stripped = removeTrailingEmptyBlock(result);
    if (stripped !== null) result = stripped;
    if (result === before) break;
  }
  return result;
}

module.exports = { stripTrailingFiller };
