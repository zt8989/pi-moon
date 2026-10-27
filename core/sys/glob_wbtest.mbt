// 段内匹配的纯逻辑：两端同码，不需要碰文件系统。

///|
test "glob 段内匹配：星号与问号" {
  assert_true(match_segment("*.mbt", "moon.pkg.mbt"))
  assert_true(match_segment("*.mbt", ".gitignore.mbt"))
  assert_false(match_segment("*.mbt", "moon.pkg"))
  assert_true(match_segment("?.mbt", "a.mbt"))
  assert_false(match_segment("?.mbt", "ab.mbt"))
  assert_true(match_segment("a*c", "abc"))
  assert_true(match_segment("a*c", "ac"))
  assert_false(match_segment("a*c", "abcd"))
  assert_true(match_segment("*", "anything"))
  assert_false(match_segment("", "x"))
  assert_true(match_segment("", ""))
}

///|
test "glob 段内匹配：字符集" {
  assert_true(match_segment("[abc].mbt", "a.mbt"))
  assert_true(match_segment("[abc].mbt", "c.mbt"))
  assert_false(match_segment("[abc].mbt", "d.mbt"))
  assert_true(match_segment("[a-c].mbt", "b.mbt"))
  assert_false(match_segment("[a-c].mbt", "z.mbt"))
  assert_true(match_segment("[!abc].mbt", "z.mbt"))
  assert_false(match_segment("[!abc].mbt", "a.mbt"))
  assert_true(match_segment("[!a-c]*", "zebra"))
  assert_false(match_segment("[!a-c]*", "bear"))
  // 未闭合的 `[` 当字面量。
  assert_true(match_segment("[abc", "[abc"))
}

///|
test "glob 路径切段" {
  assert_eq(split_path_segments("src/**/*.mbt"), ["src", "**", "*.mbt"])
  assert_eq(split_path_segments("./src//x.mbt"), ["src", "x.mbt"])
  assert_eq(split_path_segments(""), [])
}
