#!/usr/bin/env -S deno run
const url = "https://example.com"; // trailing
const pattern = /\/\/not[/]a comment/g;
const template = `a ${{ b: "//x" }.b} // still template`;
/** documentation */
export const ratio = 4 / 2; /* block */
export const all = [url, pattern, template];
