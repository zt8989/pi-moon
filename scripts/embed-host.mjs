// 把宿主脚本嵌成 MoonBit 源码里的字符串常量：
//   core/ext/host/ext_host.mjs    → core/ext/host_script.mbt   （host_script_source）
//   core/rtools/host/tool_host.mjs → core/rtools/tool_host_script.mbt（tool_host_script_source）
//
// 为什么要嵌：pi-moon 是单个可执行文件，运行期没有「资源目录」可依赖；
// 宿主脚本在启动时写到缓存目录再交给 bun。
//
// 为什么要有生成器 + 同步测试：手抄一份几百行的 JS 必然漂移。
// `moon test` 里的同步测试会在两者不一致时红。

import { readFileSync, writeFileSync } from "node:fs";

function embed(sourcePath, outputPath, constName, originNote) {
  const source = readFileSync(sourcePath, "utf8");
  const lines = source
    .split("\n")
    // 工作树可能是 CRLF（core.autocrlf）：嵌入的正文统一成 LF，否则 `#|` 行会把
    // `\r` 一起带进字符串，正文与磁盘上的那份对不上。
    .map((line) => line.replace(/\r$/, ""))
    // 末尾换行会多出一个空行，去掉
    .filter((_, index, all) => !(index === all.length - 1 && all[index] === ""));

  const embedded = lines.map((line) => "  #|" + line).join("\n");

  const output = `// 由 scripts/embed-host.mjs 从 ${originNote} 生成，不要手改。
//
// 改宿主脚本的流程：改 ${sourcePath} → 跑 \`node scripts/embed-host.mjs\`
// → 提交两份。moon test 里有同步测试兜底。

///|
/// 宿主脚本正文（bun 执行的 JS）。
pub let ${constName} : String =
${embedded}
`;

  writeFileSync(outputPath, output);
  console.log("wrote " + outputPath + " (" + lines.length + " lines)");
}

embed(
  "core/ext/host/ext_host.mjs",
  "core/ext/host_script.mbt",
  "host_script_source",
  "host/ext_host.mjs",
);
embed(
  "core/rtools/host/tool_host.mjs",
  "core/rtools/tool_host_script.mbt",
  "tool_host_script_source",
  "host/tool_host.mjs",
);
