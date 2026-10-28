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
async test "plan：未命中要打包（Node API 不再预处理拒绝）" {
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
  // `import "node:fs"` 不再被预处理拒绝：宿主跑在 bun 里，Node API 可用，
  // 读取范围由产物里的策略模块按白名单卡。
  match native.step {
    Compile(..) | Cached(..) => ()
    other => fail("期望继续装载，实际 " + other.to_string())
  }
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

