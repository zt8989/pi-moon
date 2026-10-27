// 标准流：native 侧是 @stdio 的薄包装。

///|
pub async fn write_out(text : String) -> Unit raise SysError {
  @stdio.stdout.write(text) catch {
    err => raise SysError(err.to_string())
  }
}

///|
pub async fn write_err(text : String) -> Unit raise SysError {
  @stdio.stderr.write(text) catch {
    err => raise SysError(err.to_string())
  }
}

///|
pub async fn read_stdin_all() -> String raise SysError {
  let data = @stdio.stdin.read_all() catch {
    err => raise SysError(err.to_string())
  }
  data.text() catch {
    err => raise SysError(err.to_string())
  }
}

///|
pub async fn read_stdin_until(delim : String) -> String? raise SysError {
  @stdio.stdin.read_until(delim) catch {
    err => raise SysError(err.to_string())
  }
}
