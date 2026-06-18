# PostgreSQL 扩展开发代码审查清单

## 一、项目上下文
- **技术栈**：C / Rust (pgrx) / Python (Multicorn2)
- **目标 PostgreSQL 版本**：PostgreSQL 12~17
- **核心关注点**：稳定性、内存安全、性能、与 PostgreSQL 内部机制的兼容性

## 二、通用审查项（所有语言）

### 代码规范
- [ ] 是否遵循 PostgreSQL 通用编码风格？[citation:1]
- [ ] 提交信息是否使用规范的 prefix（如 `feat:`, `fix:`, `refactor:`, `docs:` 等）？[citation:1]
- [ ] 是否包含 DCO（Developer Certificate of Origin）签名？[citation:1]
- [ ] CHANGELOG.md 是否在 `## [Unreleased]` 下记录了用户可见的变更？[citation:7]

### 测试
- [ ] `make installcheck` 或对应测试套件是否通过？[citation:4]
- [ ] 新增功能/修复是否包含对应的回归测试？[citation:4][citation:7]
- [ ] 是否在多 PostgreSQL 版本上验证了兼容性？[citation:5]

---

## 三、C 语言扩展专项审查

### 内存与资源管理
- [ ] 是否使用 `palloc()` / `pfree()` 而非 `malloc()` / `free()`？
- [ ] 是否有内存泄漏风险（尤其是在错误路径中）？[citation:10]
- [ ] 共享内存（`shmem_startup_hook`）是否合理使用且大小评估准确？[citation:10]

### Hook 使用规范
- [ ] 安装 Hook 前是否保存了原函数指针，形成 Hook 链？**注意**：这一点极为重要，若忽略可能破坏其他插件功能。[citation:10]
- [ ] 自定义函数中是否执行了原函数指针（若不为空）？[citation:10]
- [ ] Hook 函数是否足够健壮——确保不影响核心代码执行路径，需评估性能与容错机制？[citation:10]

### SPI（Server Programming Interface）使用
- [ ] 每个 `SPI_connect()` 是否都有对应的 `SPI_finish()`？[citation:3]
- [ ] `SPI_execute` 的返回值是否正确检查（如 `SPI_OK_INSERT`, `SPI_OK_SELECT`）？[citation:3]
- [ ] 是否通过 `elog(ERROR)` 正确处理了 SPI 错误？[citation:3]

### 并发与稳定性
- [ ] 扩展是否遵循 PostgreSQL 的单进程/多进程模型？[citation:2]
- [ ] 是否考虑了 MVCC、VACUUM、WAL 等核心机制的兼容性？[citation:2]

---

## 四、Rust (pgrx) 扩展专项审查

### unsafe 代码
- [ ] 所有 `unsafe` 块是否都包含 `// SAFETY:` 注释，解释为何安全？[citation:7]
- [ ] 是否存在 `unwrap()` / `panic!()` 可能被用户输入触发？**要求**：除测试代码外不得使用。[citation:7]
- [ ] 是否使用 `#[pg_guard]` 宏保护可能引发 panic 的 Rust 函数，使其转为 PostgreSQL ERROR？[citation:5]

### 内存与所有权
- [ ] 从 PostgreSQL 传递的指针是否用 `PgBox<T>` 包装以确保 RAII？[citation:5]
- [ ] 跨 FFI 边界传递数据时，所有权管理是否正确（使用 `std::mem::forget` 防止重复释放等）？[citation:8]

### SQL 与 Schema
- [ ] 新 SQL 函数是否用 `#[pg_extern(schema = "...")]` 指定了正确的 schema？[citation:7]
- [ ] 自定义类型是否正确实现了 `FromDatum` / `IntoDatum` 或使用了 `#[derive(PostgresType)]`？[citation:5]

### 工具链
- [ ] `cargo fmt` 和 `cargo clippy` 是否通过且零警告？[citation:7]
- [ ] `cargo pgrx test` 是否在所有目标 PostgreSQL 版本上通过？[citation:5]

---

## 五、报告格式

对于每个发现的问题，请按以下格式输出：

### [🔴 CRITICAL | 🟡 WARNING | 🟢 INFO]
- **文件位置**：`src/xxx.c:行号`
- **问题描述**：... 
- **修改建议**：... （附代码示例）

---

## 六、附：常用审查触发方式（供参考）

**Claude CLI 使用示例**：
```bash
claude review src/ --instructions REVIEW_INSTRUCTIONS.md