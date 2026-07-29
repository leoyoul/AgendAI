import assert from "node:assert/strict";
import test from "node:test";

import { validateReportHTML } from "../src/result_package.mjs";

function document(body, head = "") {
  return `<!doctype html><html><head>${head}</head><body>${body}</body></html>`;
}

test("HTML：允许普通 HTTPS 来源链接和已声明包内媒体", () => {
  const html = document(`
    <a href="https://example.com/source">来源</a>
    <img src="assets/a.png" srcset="assets/a.png 1x, assets/a@2x.png 2x">
    <video src="assets/a.mp4" poster="assets/poster.jpg"><track src="assets/a.vtt"></video>
    <audio src="assets/a.mp3"></audio>
    <svg><image href="assets/vector.png"></image><use href="assets/icons.svg"></use></svg>
  `);
  assert.doesNotThrow(() => validateReportHTML(html, new Set([
    "assets/a.png", "assets/a@2x.png", "assets/a.mp4", "assets/poster.jpg",
    "assets/a.vtt", "assets/a.mp3", "assets/vector.png", "assets/icons.svg",
  ])));
});

test("HTML：parse5 识别 img/source/video/audio/track 和 SVG 的远程或越界资源", () => {
  for (const body of [
    '<img src="https://example.com/a.png">',
    '<img/src="https://example.com/a.png">',
    '<source srcset="data:image/png;base64,AA 1x">',
    '<video poster="/tmp/poster.jpg"></video>',
    '<audio src="file:///tmp/a.mp3"></audio>',
    '<track src="../captions.vtt">',
    '<svg><image href="https://example.com/a.svg"></image></svg>',
    '<svg><use xlink:href="../icons.svg"></use></svg>',
  ]) {
    assert.throws(() => validateReportHTML(document(body), new Set()), /资源|相对路径|manifest/);
  }
});

test("HTML：拒绝危险标签和任意事件属性", () => {
  for (const tag of ["base", "script", "iframe", "object", "embed", "form"]) {
    assert.throws(() => validateReportHTML(document(`<${tag}></${tag}>`), new Set()), /禁止|标签/);
  }
  assert.throws(() => validateReportHTML(document('<img src="assets/a.png" onerror="alert(1)">'), new Set(["assets/a.png"])), /事件属性/);
  assert.throws(() => validateReportHTML(document('<div OnClick="alert(1)">x</div>'), new Set()), /事件属性/);
});

test("HTML：拒绝 style 属性和 style 标签中的 url() 或 @import", () => {
  assert.doesNotThrow(() => validateReportHTML(document('<div style="color: red">x</div>', "<style>body { color: black }</style>"), new Set()));
  for (const html of [
    document('<div style="background:url(https://example.com/a.png)">x</div>'),
    document("x", '<style>@import "https://example.com/a.css";</style>'),
    document("x", '<style>body{background:u/**/rl(https://example.com/a.png)}</style>'),
    document("x", '<style>body{background:\\75rl(https://example.com/a.png)}</style>'),
  ]) {
    assert.throws(() => validateReportHTML(html, new Set()), /CSS|外部资源/);
  }
});
