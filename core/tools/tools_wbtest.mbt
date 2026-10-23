// 工具表与工具执行 —— 离线测试，不碰网络。
//
// 开关规则（`defaultTools`）与 pi 逐条对齐；执行部分用 `_build/` 下的临时目录，
// 跑完就删。

///|
test "默认开启集合与 pi 的 DEFAULT_TOOL_NAMES 一致" {
  assert_eq(resolve_tool_selection(None).join(","), "read,bash,edit,write")
  // 空数组也走默认（pi 的 resolveDefaultTools 同一条分支）。
  assert_eq(resolve_tool_selection(Some([])).join(","), "read,bash,edit,write")
}

///|
test "defaultTools：带前缀的增删、不带前缀的替换" {
  // 只有 +/− → 在默认集合上打补丁。
  assert_eq(
    resolve_tool_selection(Some(["-read", "+grep"])).join(","),
    "bash,edit,write,grep",
  )
  // 出现 plain → 整份替换，+/− 再打补丁。
  assert_eq(
    resolve_tool_selection(Some(["read", "ls", "+grep", "-ls"])).join(","),
    "read,grep",
  )
  // 重复的 + 不产生重复项。
  assert_eq(
    resolve_tool_selection(Some(["read", "+grep", "+grep"])).join(","),
    "read,grep",
  )
  // 未知名字不报错也不剔除（pi 的行为：那个工具不存在，于是没开成）。
  let names = resolve_tool_selection(Some(["read", "not-a-tool"]))
  assert_eq(names.join(","), "read,not-a-tool")
  assert_eq(definitions_for(names).length(), 1)
}

///|
test "exclude_tools 从选择里去掉名字" {
  assert_eq(
    exclude_tools(["read", "bash", "grep"], ["bash"]).join(","),
    "read,grep",
  )
}

///|
test "八个内置工具都有定义，schema 是合法 JSON" {
  assert_eq(builtin_tool_names.length(), 8)
  for name in builtin_tool_names {
    let definition = match builtin_tool_definition(name) {
      Some(definition) => definition
      None => abort("missing definition: " + name)
    }
    assert_eq(definition.name, name)
    let schema = @json.parse(definition.parameters) catch {
      _ => abort("invalid schema JSON: " + name)
    }
    match schema {
      Object(_) => ()
      _ => abort("schema is not an object: " + name)
    }
  }
}

///|
test "glob 匹配器：* / ** / 字符集合" {
  assert_true(glob_match("*.mbt", "core/tools/exec.mbt"))
  assert_true(glob_match("src/**/*.spec.ts", "src/a/b/x.spec.ts"))
  assert_true(glob_match("**/*.json", "moon.mod.json"))
  assert_false(glob_match("*.mbt", "core/tools/exec.mbt.bak"))
  assert_true(glob_match("[a-c]*.txt", "beta.txt"))
  assert_false(glob_match("[a-c]*.txt", "delta.txt"))
}

///|
test "截断：头部按行 / 按字节，尾部保留最后几行" {
  let text = "1\n2\n3\n4\n5"
  let head = truncate_head(text, max_lines=2, max_bytes=1024)
  assert_eq(head.truncated, true)
  assert_eq(head.content, "1\n2")
  assert_eq(head.truncated_by, "lines")
  let tail = truncate_tail(text, max_lines=2, max_bytes=1024)
  assert_eq(tail.content, "4\n5")
  let bytes = truncate_head("abcdefghij", max_lines=100, max_bytes=4)
  assert_eq(bytes.truncated, true)
  assert_eq(bytes.truncated_by, "bytes")
}

///|
/// 一个带换行的测试文件内容。
fn e2e_text() -> String {
  "alpha\nbeta\ngamma\n"
}

///|
async fn remove_dir(path : String) -> Unit {
  @fs.rmdir(path, recursive=true) catch {
    _ => ()
  }
}

///|
async test "write → read → edit → ls → grep → find → bash 全链路" {
  let cwd = "_build/tools-e2e"
  remove_dir(cwd)
  @fs.mkdir(cwd, recursive=true)
  let write = execute(cwd, {
    id: "1",
    name: "write",
    arguments: "{\"path\":\"notes.txt\",\"content\":\"alpha\\nbeta\\ngamma\\n\"}",
  })
  assert_eq(
    @message.contents_text(write.content),
    "Successfully wrote to notes.txt",
  )
  assert_eq(write.is_error, false)

  let read = execute(cwd, {
    id: "2",
    name: "read",
    arguments: "{\"path\":\"notes.txt\"}",
  })
  assert_eq(read.is_error, false)
  assert_eq(@message.contents_text(read.content), e2e_text())

  // offset / limit：1-indexed。
  let slice = execute(cwd, {
    id: "3",
    name: "read",
    arguments: "{\"path\":\"notes.txt\",\"offset\":2,\"limit\":1}",
  })
  let slice_text = @message.contents_text(slice.content)
  assert_true(slice_text.has_prefix("beta"))
  assert_true(slice_text.contains("more lines in file"))

  let edit = execute(cwd, {
    id: "4",
    name: "edit",
    arguments: "{\"path\":\"notes.txt\",\"edits\":[{\"oldText\":\"beta\",\"newText\":\"BETA\"}]}",
  })
  assert_eq(edit.is_error, false)
  let after = execute(cwd, {
    id: "5",
    name: "read",
    arguments: "{\"path\":\"notes.txt\"}",
  })
  assert_true(@message.contents_text(after.content).contains("BETA"))

  // 不唯一的 oldText 必须被拒绝（pi 的同一条规则）。
  let duplicate = execute(cwd, {
    id: "6",
    name: "edit",
    arguments: "{\"path\":\"notes.txt\",\"edits\":[{\"oldText\":\"a\",\"newText\":\"z\"}]}",
  })
  assert_eq(duplicate.is_error, true)

  @fs.mkdir(cwd + "/sub", recursive=true)
  @fs.write_file(cwd + "/.hidden", "x")
  let ls = execute(cwd, { id: "7", name: "ls", arguments: "{}", })
  let listing = @message.contents_text(ls.content)
  assert_true(listing.contains("notes.txt"))
  assert_true(listing.contains("sub/"))
  assert_true(listing.contains(".hidden"))

  let grep = execute(cwd, {
    id: "8",
    name: "grep",
    arguments: "{\"pattern\":\"BETA\",\"path\":\".\"}",
  })
  let grep_text = @message.contents_text(grep.content)
  assert_eq(grep.is_error, false)
  assert_true(grep_text.contains("notes.txt"))

  // 直接搜一个文件（不是目录），路径按 basename 输出。
  let grep_file = execute(cwd, {
    id: "8b",
    name: "grep",
    arguments: "{\"pattern\":\"BETA\",\"path\":\"notes.txt\"}",
  })
  let grep_file_text = @message.contents_text(grep_file.content)
  assert_eq(grep_file.is_error, false)
  assert_true(grep_file_text.has_prefix("notes.txt:2: "))

  // context：前后各一行，用 '-' 分隔；匹配行用 ':'。
  let grep_context = execute(cwd, {
    id: "8c",
    name: "grep",
    arguments: "{\"pattern\":\"BETA\",\"context\":1}",
  })
  let context_text = @message.contents_text(grep_context.content)
  assert_true(context_text.contains("-1- alpha"))
  assert_true(context_text.contains(":2: BETA"))
  assert_true(context_text.contains("-3- gamma"))

  let find = execute(cwd, {
    id: "9",
    name: "find",
    arguments: "{\"pattern\":\"*.txt\",\"path\":\".\"}",
  })
  assert_eq(find.is_error, false)
  assert_true(@message.contents_text(find.content).contains("notes.txt"))

  let bash = execute(cwd, {
    id: "10",
    name: "bash",
    arguments: "{\"command\":\"printf tool-ok\"}",
  })
  let bash_text = @message.contents_text(bash.content)
  assert_eq(bash.is_error, false)
  assert_true(bash_text.contains("tool-ok"))

  // 非零退出码是「错误结果」，不是异常。
  let failing = execute(cwd, {
    id: "11",
    name: "bash",
    arguments: "{\"command\":\"exit 3\"}",
  })
  assert_eq(failing.is_error, true)
  assert_true(
    @message.contents_text(failing.content).contains("exited with code 3"),
  )

  remove_dir(cwd)
}

///|
async test "bash 能拿到 PI_* 会话环境变量" {
  let env : Map[String, String] = Map([])
  env["PI_MODEL"] = "m-1"
  let outcome = execute(
    ".",
    {
      id: "1",
      name: "bash",
      arguments: "{\"command\":\"printf %s \\\"$PI_MODEL\\\"\"}",
    },
    env~,
  )
  assert_eq(@message.contents_text(outcome.content), "m-1")
}

///|
async test "未启用的工具不可执行（与 pi 的执行侧过滤一致）" {
  let outcome = execute(
    ".",
    { id: "1", name: "bash", arguments: "{\"command\":\"printf nope\"}", },
    enabled=["read"],
  )
  assert_eq(outcome.is_error, true)
  assert_true(@message.contents_text(outcome.content).contains("未知工具"))
}

///|
async test "未知工具与坏参数都落成错误结果" {
  let unknown = execute(".", { id: "1", name: "nope", arguments: "{}", })
  assert_eq(unknown.is_error, true)
  assert_true(@message.contents_text(unknown.content).contains("未知工具"))

  let bad_json = execute(".", { id: "2", name: "read", arguments: "{not json", })
  assert_eq(bad_json.is_error, true)

  let missing = execute(".", { id: "3", name: "read", arguments: "{}", })
  assert_eq(missing.is_error, true)
  assert_true(@message.contents_text(missing.content).contains("path"))
}

///|
async test "edit 保留 CRLF 与 BOM，read 把图片变成 image 块" {
  let cwd = "_build/tools-encoding"
  remove_dir(cwd)
  @fs.mkdir(cwd, recursive=true)
  @fs.write_file(cwd + "/crlf.txt", "\u{feff}one\r\ntwo\r\n")
  let edit = execute(cwd, {
    id: "1",
    name: "edit",
    arguments: "{\"path\":\"crlf.txt\",\"edits\":[{\"oldText\":\"two\",\"newText\":\"TWO\"}]}",
  })
  assert_eq(edit.is_error, false)
  let data = @fs.read_file(cwd + "/crlf.txt")
  assert_eq(@utf8.decode_lossy(data.binary()), "\u{feff}one\r\nTWO\r\n")

  @fs.write_file(cwd + "/tiny.png", "not-a-real-png")
  let image = execute(cwd, {
    id: "2",
    name: "read",
    arguments: "{\"path\":\"tiny.png\"}",
  })
  assert_eq(image.is_error, false)
  assert_eq(image.content.length(), 2)
  let note = @message.content_text(image.content[0])
  assert_true(note.contains("image/png"))
  match image.content[1] {
    @message.Image(url) => assert_true(url.has_prefix("data:image/png;base64,"))
    _ => abort("expected an image block")
  }
  remove_dir(cwd)
}

///|
async test "powershell：Windows 上能跑，其它平台给明确错误" {
  let windows = is_windows_env(@env.get_env_vars())
  let outcome = execute(".", {
    id: "1",
    name: "powershell",
    arguments: "{\"command\":\"Write-Output ps-ok\"}",
  })
  let text = @message.contents_text(outcome.content)
  if windows {
    assert_eq(outcome.is_error, false)
    assert_true(text.contains("ps-ok"))
  } else {
    assert_eq(outcome.is_error, true)
    assert_true(text.contains("only available on Windows"))
  }
}

///|
