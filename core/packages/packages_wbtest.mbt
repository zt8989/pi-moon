// 包清单解析 —— 离线测试，用 `_build/` 下的临时目录。

///|
fn pkg_root(name : String) -> String {
  "_build/packages-test/" + name
}

///|
/// 落一个夹具文件。并行测试在共享前缀（`_build/…`）上的 recursive mkdir
/// 偶发竞态（先建的那位还没建完，后建的 open 就 ENOENT）—— 建目录带重试。
async fn pkg_put(path : String, content : String) -> Unit {
  let parent = path[:path.rev_find("/").unwrap()].to_owned()
  for _ in 0..<10 {
    @fs.mkdir(parent, recursive=true) catch {
      _ => ()
    }
    let there = @sys.exists(parent) catch { _ => false }
    if there {
      break
    }
    @async.sleep(10)
  }
  @fs.write_file(path, content)
}

///|
async test "resolve：正常包解析出三类资源，异常包各留一条诊断" {
  let root = pkg_root("normal")
  pkg_put(
    root + "/settings.json",
    "{\"packages\":[\"npm:demo-pkg\",\"npm:broken-pkg\",\"npm:nomanifest-pkg\",\"npm:missing-pkg\",\"git:weird\"]}",
  )
  pkg_put(
    root + "/npm/node_modules/demo-pkg/package.json",
    "{\"pi\":{\"extensions\":[\"./bundle/index.js\"],\"skills\":[\"./skills\"],\"prompts\":[\"./prompts\"]}}",
  )
  pkg_put(
    root + "/npm/node_modules/demo-pkg/bundle/index.js",
    "export default function () {}",
  )
  pkg_put(
    root + "/npm/node_modules/demo-pkg/skills/council-mode/SKILL.md",
    "---\nname: council-mode\ndescription: 演示\n---\n正文",
  )
  pkg_put(
    root + "/npm/node_modules/demo-pkg/prompts/council.md",
    "跑 council",
  )
  pkg_put(
    root + "/npm/node_modules/broken-pkg/package.json",
    "{oops",
  )
  pkg_put(
    root + "/npm/node_modules/nomanifest-pkg/package.json",
    "{\"name\":\"nomanifest-pkg\"}",
  )
  let (packages, diagnostics) = resolve(root)
  assert_eq(packages.length(), 1)
  let demo = packages[0]
  assert_eq(demo.name, "demo-pkg")
  assert_eq(demo.extensions.join(","), "bundle/index.js")
  assert_eq(demo.skills.join(","), "skills")
  assert_eq(demo.prompts.join(","), "prompts")
  assert_true(demo.dir.contains("npm/node_modules/demo-pkg"))
  assert_eq(diagnostics.length(), 4)
  assert_true(diagnostics.any(fn(d) { d.contains("解析失败") && d.contains("broken-pkg") }))
  assert_true(diagnostics.any(fn(d) { d.contains("没有 \"pi\" 声明") && d.contains("nomanifest-pkg") }))
  assert_true(diagnostics.any(fn(d) { d.contains("未安装") && d.contains("missing-pkg") }))
  assert_true(diagnostics.any(fn(d) { d.contains("不是 npm: 分发方式") && d.contains("git:weird") }))
}

///|
async test "resolve：空声明、坏键型与路径不存在的各自处理" {
  let root = pkg_root("edge")
  pkg_put(
    root + "/settings.json",
    "{\"packages\":[\"npm:empty-pkg\",\"npm:badtype-pkg\",\"npm:nope-pkg\"]}",
  )
  pkg_put(
    root + "/npm/node_modules/empty-pkg/package.json",
    "{\"pi\":{}}",
  )
  pkg_put(
    root + "/npm/node_modules/badtype-pkg/package.json",
    "{\"pi\":{\"skills\":\"not-an-array\",\"extensions\":[\"ok.ts\",42]}}",
  )
  pkg_put(root + "/npm/node_modules/badtype-pkg/ok.ts", "export {}")
  pkg_put(
    root + "/npm/node_modules/nope-pkg/package.json",
    "{\"pi\":{\"skills\":[\"./ghost\"]}}",
  )
  let (packages, diagnostics) = resolve(root)
  // badtype-pkg 的 extensions 里有合法条目（ok.ts），照常贡献。
  assert_eq(packages.length(), 1)
  assert_eq(packages[0].name, "badtype-pkg")
  assert_eq(packages[0].extensions.join(","), "ok.ts")
  // empty-pkg：声明为空。
  assert_true(diagnostics.any(fn(d) { d.contains("声明为空") && d.contains("empty-pkg") }))
  // badtype-pkg：键不是数组 + 数组里的非字符串条目。
  assert_true(diagnostics.any(fn(d) { d.contains("不是数组") && d.contains("badtype-pkg") }))
  assert_true(diagnostics.any(fn(d) { d.contains("非字符串条目") && d.contains("badtype-pkg") }))
  // nope-pkg：声明了但路径不存在，整包丢弃。
  assert_true(diagnostics.any(fn(d) { d.contains("路径不存在") && d.contains("nope-pkg") }))
  assert_true(!diagnostics.any(fn(d) { d.contains("nope-pkg") && d.contains("声明为空") }))
}

///|
async test "resolve：settings 缺失或没有 packages 键 → 空、零诊断" {
  let root = pkg_root("quiet")
  pkg_put(root + "/settings.json", "{\"defaultModel\":\"x\"}")
  let (packages, diagnostics) = resolve(root)
  assert_eq(packages.length(), 0)
  assert_eq(diagnostics.length(), 0)
  // settings.json 都不存在（连目录都没有）也一样安静。
  let (none_packages, none_diagnostics) = resolve(pkg_root("nonexistent"))
  assert_eq(none_packages.length(), 0)
  assert_eq(none_diagnostics.length(), 0)
}

///|
async test "resolve：空 npm: 条目一条诊断" {
  let root = pkg_root("blank")
  pkg_put(root + "/settings.json", "{\"packages\":[\"npm:\"]}")
  let (packages, diagnostics) = resolve(root)
  assert_eq(packages.length(), 0)
  assert_true(diagnostics.any(fn(d) { d.contains("空的 npm: 条目") }))
}

///|
async test "resolve：声明越出包目录的路径被拒" {
  let root = pkg_root("escape")
  pkg_put(
    root + "/settings.json",
    "{\"packages\":[\"npm:escape-pkg\"]}",
  )
  pkg_put(
    root + "/npm/node_modules/escape-pkg/package.json",
    "{\"pi\":{\"skills\":[\"../elsewhere\"],\"prompts\":[\"./ok-dir\"]}}",
  )
  pkg_put(root + "/npm/node_modules/escape-pkg/ok-dir/a.md", "x")
  let (packages, diagnostics) = resolve(root)
  assert_eq(packages.length(), 1)
  assert_eq(packages[0].prompts.join(","), "ok-dir")
  assert_eq(packages[0].skills.length(), 0)
  assert_true(diagnostics.any(fn(d) { d.contains("越出包目录") && d.contains("escape-pkg") }))
}

///|
test "normalize_entry：./ 前缀、反斜杠与两端斜杠" {
  assert_eq(normalize_entry("./skills"), "skills")
  assert_eq(normalize_entry("skills/"), "skills")
  assert_eq(normalize_entry(".\\bundle\\index.js"), "bundle/index.js")
  assert_eq(normalize_entry("  ./prompts  "), "prompts")
  assert_eq(normalize_entry("./"), "")
  assert_eq(normalize_entry("a/./b"), "a/b")
}
