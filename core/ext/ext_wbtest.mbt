// 扩展发现与体检 —— 纯逻辑部分不摸磁盘，发现/缓存部分用 `_build/` 下的临时目录。

///|
fn ext_root() -> String {
  "_build/ext-test"
}

///|
/// 每次跑测试都用新的目录：缓存文件会让「首次必须 Compile」的断言在第二次运行挂掉。
async fn make_dir(name : String) -> String {
  let random = @random.Rand::Rand()
  let dir = ext_root() +
    "/" +
    name +
    "-" +
    @sys.now().to_string() +
    "-" +
    random.int(limit=1000000).to_string()
  @fs.mkdir(dir, recursive=true) catch { _ => () }
  dir
}

///|
async fn put(path : String, content : String) -> Unit {
  @fs.mkdir(parent_dir(path), recursive=true) catch { _ => () }
  @fs.write_file(path, content)
}

///|
test "fnv1a64：已知向量" {
  // FNV-1a 64 的空串与 "a" 是公开测试向量。
  assert_eq(fnv1a64(""), 0xCBF29CE484222325UL)
  assert_eq(fnv1a64("a"), 0xAF63DC4C8601EC8CUL)
  assert_eq(hex64(0UL), "0000000000000000")
  assert_eq(hex64(fnv1a64("a")), "af63dc4c8601ec8c")
}

///|
test "cache_key：源码、预置脚本、沙盒版本任一变化都要换键" {
  let base = cache_key("let a = 1", prelude_version="p1", sandbox_version="s1")
  assert_eq(base.length(), 16)
  assert_eq(base, cache_key("let a = 1", prelude_version="p1", sandbox_version="s1"))
  assert_true(base != cache_key("let a = 2", prelude_version="p1", sandbox_version="s1"))
  assert_true(base != cache_key("let a = 1", prelude_version="p2", sandbox_version="s1"))
  assert_true(base != cache_key("let a = 1", prelude_version="p1", sandbox_version="s2"))
  // 分隔符不能缺：否则 ("p1s", "1") 与 ("p1", "s1") 撞键。
  assert_true(
    cache_key("", prelude_version="p1s", sandbox_version="1") !=
    cache_key("", prelude_version="p1", sandbox_version="s1"),
  )
}

///|
test "stem_of / parent_dir" {
  assert_eq(stem_of("/a/b/hello.ts"), "hello")
  assert_eq(stem_of("/a/b/hello.mjs"), "hello")
  assert_eq(stem_of("/a/b/demo/index.ts"), "demo")
  assert_eq(stem_of("/a/b/demo/index.js"), "demo")
  assert_eq(parent_dir("/a/b/c.ts"), "/a/b")
  assert_eq(parent_dir("c.ts"), ".")
}

///|
test "import_specifiers：静态、动态、require、多行" {
  let source =
    #|import fs from "node:fs";
    #|import { a, b } from './local.js'
    #|export { c } from "pkg"
    #|const d = await import("dyn-pkg")
    #|const e = require("cjs-pkg")
    #|import "side-effect"
  let specs = import_specifiers(source)
  assert_eq(
    specs,
    ["node:fs", "./local.js", "pkg", "dyn-pkg", "cjs-pkg", "side-effect"],
  )
}

///|
test "import_specifiers：注释与字符串里的 import 不算" {
  let source =
    #|// import evil from "node:fs"
    #|/* require("node:child_process") */
    #|const text = "import x from 'node:net'"
    #|const value = 1
  assert_eq(import_specifiers(source), [])
}

///|
test "classify_specifier：内建、前缀、相对、裸包" {
  assert_eq(classify_specifier("node:fs"), NodeBuiltin)
  assert_eq(classify_specifier("fs"), NodeBuiltin)
  assert_eq(classify_specifier("child_process"), NodeBuiltin)
  assert_eq(classify_specifier("fs/promises"), Package)
  assert_eq(classify_specifier("./util.js"), Relative)
  assert_eq(classify_specifier("../up.js"), Relative)
  assert_eq(classify_specifier("/abs.js"), Relative)
  assert_eq(classify_specifier("lodash"), Package)
  assert_eq(classify_specifier(""), Allowed)
}

///|
test "first_unsupported_import：只报第一个坏说明符" {
  assert_eq(first_unsupported_import("const a = 1"), None)
  assert_eq(
    first_unsupported_import("import fs from \"node:fs\"; import os from \"os\""),
    Some((NodeBuiltin, "node:fs")),
  )
  // 相对的坏说明符同样拦下来：沙盒里没有模块加载器。
  assert_eq(
    first_unsupported_import("import x from \"./x.js\""),
    Some((Relative, "./x.js")),
  )
}

///|
async test "discover：用户级 + 项目级 + 目录式扩展，同名先到先得" {
  let root = make_dir("discover")
  let agent = root + "/agent"
  let cwd = root + "/project"
  put(agent + "/extensions/alpha.ts", "const a = 1")
  put(agent + "/extensions/demo/index.ts", "const b = 2")
  put(agent + "/extensions/node_modules/ignored.ts", "const c = 3")
  put(agent + "/extensions/.hidden.ts", "const d = 4")
  put(cwd + "/.pi/extensions/beta.js", "const e = 5")
  put(cwd + "/.pi/extensions/alpha.ts", "const f = 6")
  let (sources, diagnostics) = discover(cwd, agent)
  let names = sources.map(source => source.name)
  // 顺序由 readdir 的确定序决定（不保证字典序），这里只认集合与来源。
  assert_eq(names.length(), 3)
  assert_true(names.contains("alpha"))
  assert_true(names.contains("demo"))
  assert_true(names.contains("beta"))
  // 项目级的 alpha 被用户级的挡下来，并且留下一条诊断。
  assert_true(diagnostics.any(line => line.contains("重名") && line.contains("alpha")))
  let demo = sources.filter(source => source.name == "demo")[0]
  assert_eq(demo.origin, User)
  assert_eq(demo.path, agent + "/extensions/demo/index.ts")
  let beta = sources.filter(source => source.name == "beta")[0]
  assert_eq(beta.origin, Project)
}

///|
async test "plan：命中缓存 / 需要编译 / 因 Node 依赖跳过" {
  let root = make_dir("plan")
  let agent = root + "/agent"
  put(agent + "/extensions/good.ts", "const a = 1")
  put(agent + "/extensions/native.ts", "import fs from \"node:fs\"\nconst a = 1")
  let planned = plan(root + "/project", agent)
  let good = planned.entries.filter(entry => entry.source.name == "good")[0]
  let native = planned.entries.filter(entry => entry.source.name == "native")[0]
  match good.step {
    Compile(cache_key~, path~, ..) => {
      // 未命中时给的是「要编译」，缓存路径在 agent 目录下的 ext 缓存里。
      assert_true(path.has_prefix(agent + "/cache/pi-moon/ext/"))
      assert_true(path.has_suffix(cache_key + ".snapshot"))
    }
    other => fail("期望 Compile，实际 " + other.to_string())
  }
  match native.step {
    Skip(reason~) => assert_eq(reason, NodeDependency("node:fs"))
    other => fail("期望 Skip，实际 " + other.to_string())
  }
  assert_true(planned.diagnostics.any(line => line.contains("node:fs")))
}

///|
async test "plan：缓存文件存在时走 Cached，不再编译" {
  let root = make_dir("cached")
  let agent = root + "/agent"
  put(agent + "/extensions/good.ts", "const a = 1")
  let first = plan(root + "/project", agent)
  let cache_path = match first.entries[0].step {
    Compile(path~, ..) => path
    other => fail("首次应为 Compile，实际 " + other.to_string())
  }
  put(cache_path, "snapshot")
  let second = plan(root + "/project", agent)
  match second.entries[0].step {
    Cached(path~, ..) => assert_eq(path, cache_path)
    other => fail("缓存存在时应为 Cached，实际 " + other.to_string())
  }
}
