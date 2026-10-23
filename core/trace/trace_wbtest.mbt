// 轨迹树的纯函数断言：tip 规则、容器、重试统计、渲染缩进。

///|
test "只有闭合的对话节点推进 tip" {
  let tree = create_trace_tree("s1")
  let (tree, user) = append_node(
    tree,
    None,
    User,
    Ok,
    "你好",
    1L,
    ended_at=1L,
  )
  assert_eq(tree.tip_id, Some(user.id))
  // turn.start 是容器：不推进 tip。
  let (tree, turn) = append_node(
    tree,
    Some(user.id),
    TurnStart,
    Pending,
    "回合 1",
    2L,
  )
  assert_eq(tree.tip_id, Some(user.id))
  // step.start 也是容器。
  let (tree, step) = append_node(
    tree,
    Some(turn.id),
    StepStart,
    Pending,
    "第 1 步",
    3L,
  )
  assert_eq(tree.tip_id, Some(user.id))
  // error 不推进 tip。
  let (tree, _error) = append_node(
    tree,
    Some(step.id),
    ErrorNode,
    Errored,
    "超时",
    4L,
    ended_at=4L,
  )
  assert_eq(tree.tip_id, Some(user.id))
  // llm.result 推进 tip。
  let (tree, result) = append_node(
    tree,
    Some(step.id),
    LlmResult,
    Ok,
    "答",
    5L,
    ended_at=5L,
  )
  assert_eq(tree.tip_id, Some(result.id))
}

///|
test "pending 容器闭合后也不推进 tip" {
  let tree = create_trace_tree("s2")
  let (tree, step) = append_node(
    tree,
    None,
    StepStart,
    Pending,
    "第 1 步",
    1L,
  )
  let tree = patch_node(tree, step.id, status=Ok, ended_at=2L)
  assert_eq(tree.tip_id, None)
}

///|
test "重试计数：同一 step 容器里成功收口时，每个 error 都算一次重试" {
  let tree = create_trace_tree("s3")
  let (tree, user) = append_node(tree, None, User, Ok, "hi", 1L, ended_at=1L)
  let (tree, turn) = append_node(
    tree,
    Some(user.id),
    TurnStart,
    Pending,
    "回合 1",
    2L,
  )
  let (tree, step) = append_node(
    tree,
    Some(turn.id),
    StepStart,
    Pending,
    "第 1 步",
    3L,
  )
  let (tree, _e1) = append_node(
    tree,
    Some(step.id),
    ErrorNode,
    Errored,
    "超时",
    4L,
    ended_at=4L,
  )
  let (tree, _e2) = append_node(
    tree,
    Some(step.id),
    ErrorNode,
    Errored,
    "又超时",
    5L,
    ended_at=5L,
  )
  let tree = patch_node(tree, step.id, status=Ok, ended_at=6L)
  let (tree, _result) = append_node(
    tree,
    Some(step.id),
    LlmResult,
    Ok,
    "答",
    6L,
    ended_at=6L,
  )
  let stats = trace_stats(tree)
  assert_eq(stats.steps, 1)
  assert_eq(stats.errors, 2)
  assert_eq(stats.retries, 2)
}

///|
test "渲染：容器给子孙加一级缩进，闭合点画在容器那一列" {
  let tree = create_trace_tree("s4")
  let (tree, _u) = append_node(
    tree,
    None,
    User,
    Ok,
    "查两个",
    0L,
    ended_at=0L,
  )
  let (tree, turn) = append_node(
    tree,
    Some("n1"),
    TurnStart,
    Pending,
    "回合 1",
    1L,
  )
  let (tree, step) = append_node(
    tree,
    Some(turn.id),
    StepStart,
    Pending,
    "第 1 步",
    2L,
  )
  let (tree, _r) = append_node(
    tree,
    Some(step.id),
    LlmResult,
    Ok,
    "并行",
    3L,
    ended_at=3L,
  )
  let (tree, _se) = append_node(
    tree,
    Some(step.id),
    StepEnd,
    Ok,
    "第 1 步结束",
    4L,
    ended_at=4L,
  )
  let (tree, _te) = append_node(
    tree,
    Some(turn.id),
    TurnEnd,
    Ok,
    "回合 1 结束",
    5L,
    ended_at=5L,
  )
  let rows = trace_rows(tree, max_width=0)
  assert_eq(rows.length(), 6)
  // 容器里的节点多一级轨道。
  assert_true(rows[1].prefix == "○  ")
  assert_true(rows[2].prefix == "│  ○  ")
  assert_true(rows[3].prefix == "│  │  ○  ")
  // 闭合点与容器同列。
  assert_true(rows[4].prefix == "│  └─ ")
  assert_true(rows[5].prefix == "└─ ")
}
