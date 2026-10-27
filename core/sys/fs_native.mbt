// 文件系统：native 侧就是 moonbitlang/async/fs 的薄包装。

///|
pub async fn read_bytes(path : String) -> Bytes raise SysError {
  let data = @fs.read_file(path) catch {
    err => raise SysError(err.to_string())
  }
  data.binary()
}

///|
pub async fn read_text(path : String) -> String raise SysError {
  let data = @fs.read_file(path) catch {
    err => raise SysError(err.to_string())
  }
  data.text() catch {
    err => raise SysError(err.to_string())
  }
}

///|
pub async fn write_text(
  path : String,
  content : String,
  append? : Bool = false,
) -> Unit raise SysError {
  let create_mode = if append { @fs.OpenOrCreate } else { @fs.CreateOrTruncate }
  @fs.write_file(path, content, append~, create_mode~) catch {
    err => raise SysError(err.to_string())
  }
}

///|
pub async fn exists(path : String) -> Bool raise SysError {
  @fs.exists(path) catch {
    err => raise SysError(err.to_string())
  }
}

///|
pub async fn kind(path : String) -> Kind raise SysError {
  let kind = @fs.kind(path) catch {
    err => raise SysError(err.to_string())
  }
  match kind {
    @fs.Regular => Regular
    @fs.Directory => Directory
    _ => Other
  }
}

///|
pub async fn readdir(
  path : String,
  include_hidden? : Bool = true,
) -> Array[String] raise SysError {
  @fs.readdir(path, include_hidden~) catch {
    err => raise SysError(err.to_string())
  }
}

///|
pub async fn mkdir_p(path : String) -> Unit raise SysError {
  @fs.mkdir(path, recursive=true) catch {
    err => raise SysError(err.to_string())
  }
}

///|
pub async fn tmpdir(prefix : String) -> String raise SysError {
  @fs.tmpdir(prefix~) catch {
    err => raise SysError(err.to_string())
  }
}

///|
/// 修改时间（Unix 毫秒）。会话面板按它排序。
pub async fn mtime(path : String) -> Int64 raise SysError {
  let (mtime, _) = @fs.mtime(path) catch {
    err => raise SysError(err.to_string())
  }
  mtime
}

///|
pub async fn file_size(path : String) -> Int64 raise SysError {
  @fs.file_size(path) catch {
    err => raise SysError(err.to_string())
  }
}

///|
/// 递归删目录（测试清理用）。
pub async fn remove_dir(path : String) -> Unit raise SysError {
  @fs.rmdir(path, recursive=true) catch {
    err => raise SysError(err.to_string())
  }
}
