// 行协议会话的内存双工测试：协议行为在这里钉住，与承载无关。
//
// 与 core/ext 的 serve_wbtest 分工：那边用 node 假宿主钉「stdio 上的整条
// ext 链路」，这里用内存双工钉「协议本身」—— 毫秒级、无外部进程、任何机器
// 都能跑。这同时是「传输可插拔」的内存侧证明（stdio 侧由 ext 的假宿主与
// 真 bun 组证明）。

///|
/// 内存双工的记录器：断言「写出了什么、调了几次」。
struct MemRecorder {
  mut reads : Int
  mut writes : Int
  written : Array[String]
  mut closes : Int
}

///|
/// 脚本化的内存双工：`incoming` 按 read 顺序消费（读尽即 EOF）；
/// `fail_read_on` / `fail_write_on`（1 起）让第 N 次读 / 写按剧本返回 Err。
fn mem_duplex(
  incoming~ : Array[String] = [],
  fail_read_on? : Int,
  fail_write_on? : Int,
) -> (Duplex, MemRecorder) {
  let rec = { reads: 0, writes: 0, written: [], closes: 0 }
  let queue = incoming
  let duplex : Duplex = {
    read: fn(_max) {
      rec.reads += 1
      let forced = match fail_read_on {
        Some(n) => rec.reads == n
        None => false
      }
      if forced {
        Err("第 N 次读按剧本失败")
      } else if queue.is_empty() {
        Ok(None)
      } else {
        Ok(Some(@utf8.encode(queue.remove(0))))
      }
    },
    write: fn(text) {
      rec.writes += 1
      let forced = match fail_write_on {
        Some(n) => rec.writes == n
        None => false
      }
      if forced {
        Err("第 N 次写按剧本失败")
      } else {
        rec.written.push(text)
        Ok(())
      }
    },
    close: fn() { rec.closes += 1 },
  }
  (duplex, rec)
}

///|
/// 发一次请求，成功交回响应字段，失败直接判红（happy-path 助手）。
async fn must_request(
  session : Session,
  payload : Map[String, Json],
) -> Map[String, Json] {
  match session.request(payload) {
    Ok(fields) => fields
    Err(e) => fail("请求不该失败，拿到：" + e.to_string())
  }
}

///|
async test "request/response：写出的请求带自增 id，读到匹配 id 的响应" {
  let (duplex, rec) = mem_duplex(
    incoming=["{\"ok\":true,\"id\":1,\"result\":{\"x\":1}}\n"],
  )
  let session = Session::new(duplex)
  let payload : Map[String, Json] = Map([])
  payload["op"] = Json::string("call")
  let response = must_request(session, payload)
  assert_eq(field_int(response, "id"), Some(1))
  assert_eq(rec.written.length(), 1)
  assert_true(rec.written[0].contains("\"id\":1"))
  assert_true(rec.written[0].contains("\"op\":\"call\""))
  assert_false(session.is_dead())
  session.close()
  assert_eq(rec.closes, 1)
}

///|
async test "协议是行：一行跨多个块要攒尾巴，成行才交回" {
  let (duplex, _rec) = mem_duplex(
    incoming=[
      "{\"ok\":true,\"i",
      "d\":1,\"result\":{\"text\":\"hi\"}}\n",
    ],
  )
  let session = Session::new(duplex)
  let response = must_request(session, Map([]))
  assert_eq(field_int(response, "id"), Some(1))
}

///|
async test "对端只走协议：log 行与非 JSON 行进噪音，不污染响应流" {
  let lines = [
    "{\"event\":\"log\",\"text\":\"[fake] 正常说话\"}\n",
    "这不是 JSON\n",
    "{\"ok\":true,\"id\":1,\"result\":{}}\n",
  ]
  let (duplex, _rec) = mem_duplex(incoming=lines)
  let session = Session::new(duplex)
  let response = must_request(session, Map([]))
  assert_eq(field_int(response, "id"), Some(1))
  assert_true(session.noise_text().contains("[fake] 正常说话"))
  assert_true(session.noise_text().contains("这不是 JSON"))
}

///|
async test "噪音只留最近几条，不会随会话变长" {
  let lines : Array[String] = []
  for i in 0..<12 {
    lines.push("{\"event\":\"log\",\"text\":\"n" + i.to_string() + "\"}\n")
  }
  lines.push("{\"ok\":true,\"id\":1}\n")
  let (duplex, _rec) = mem_duplex(incoming=lines)
  let session = Session::new(duplex)
  let _ = must_request(session, Map([]))
  let noise = session.noise_text()
  // 噪音里存的是 log 的 text 值（与扩展宿主同口径）。
  assert_false(noise.contains("n0"))
  assert_false(noise.contains("n3"))
  assert_true(noise.contains("n4"))
  assert_true(noise.contains("n11"))
}

///|
async test "id 自检：上一轮剩下的响应抖掉，继续等匹配的那条" {
  let (duplex, _rec) = mem_duplex(
    incoming=[
      "{\"ok\":true,\"id\":99,\"stale\":true}\n",
      "{\"ok\":true,\"id\":1,\"fresh\":true}\n",
    ],
  )
  let session = Session::new(duplex)
  let response = must_request(session, Map([]))
  assert_eq(field_int(response, "id"), Some(1))
  assert_eq(response.get("fresh"), Some(Json::boolean(true)))
}

///|
async test "fatal：当前调用拿到带原因的错误，会话标死，之后调用立刻失败" {
  let (duplex, _rec) = mem_duplex(
    incoming=["{\"event\":\"fatal\",\"error\":\"boom-from-peer\"}\n"],
  )
  let session = Session::new(duplex)
  let message = match session.request(Map([])) {
    Ok(_) => fail("应该报 PeerFatal")
    Err(PeerFatal(reason)) => reason
    Err(other) => fail("应该报 PeerFatal，拿到：" + other.to_string())
  }
  assert_true(message.contains("boom-from-peer"))
  assert_true(session.is_dead())
  let again = match session.request(Map([])) {
    Ok(_) => fail("应该报 SessionClosed")
    Err(SessionClosed) => "closed"
    Err(other) => fail("应该报 SessionClosed，拿到：" + other.to_string())
  }
  assert_eq(again, "closed")
}

///|
async test "对端 EOF：等响应时读到尽头报 PeerClosed，之后不再写" {
  let (duplex, rec) = mem_duplex(incoming=[])
  let session = Session::new(duplex)
  let first = match session.request(Map([])) {
    Ok(_) => fail("应该报 PeerClosed")
    Err(PeerClosed) => "eof"
    Err(other) => fail("应该报 PeerClosed，拿到：" + other.to_string())
  }
  assert_eq(first, "eof")
  assert_true(session.is_dead())
  let _ = match session.request(Map([])) {
    Ok(_) => fail("应该报 SessionClosed")
    Err(SessionClosed) => "closed"
    Err(other) => fail("应该报 SessionClosed，拿到：" + other.to_string())
  }
  assert_eq(rec.writes, 1)
}

///|
async test "写失败：标死，错误带底层原因" {
  let (duplex, rec) = mem_duplex(fail_write_on=1)
  let session = Session::new(duplex)
  let message = match session.request(Map([])) {
    Ok(_) => fail("应该报 TransportWrite")
    Err(TransportWrite(reason)) => reason
    Err(other) => fail("应该报 TransportWrite，拿到：" + other.to_string())
  }
  assert_true(message.contains("按剧本失败"))
  assert_true(session.is_dead())
  assert_eq(rec.written.length(), 0)
}

///|
async test "读失败：标死，错误带底层原因" {
  let (duplex, _rec) = mem_duplex(fail_read_on=1)
  let session = Session::new(duplex)
  let message = match session.request(Map([])) {
    Ok(_) => fail("应该报 TransportRead")
    Err(TransportRead(reason)) => reason
    Err(other) => fail("应该报 TransportRead，拿到：" + other.to_string())
  }
  assert_true(message.contains("按剧本失败"))
  assert_true(session.is_dead())
}
