# seekdb-vector

一个给 AI Agent 用的 Skill：在本机用 [seekdb](https://github.com/oceanbase/seekdb) 搭向量检索，从起库到第一次近似查询，走完不踩坑。

SKILL.md 里的每条 DDL/DML 和返回值都在 `oceanbase/seekdb:latest`（`seekdb-v1.4.0.0`）上实跑过，标「实测」的是真实输出，不是示意。

## 它解决什么

向量库的坑很少在「怎么写查询」，多在「为什么结果不对」：

- `ORDER BY round(l2_distance(...)) APPROXIMATE` 直接报 `Using vector index without vector_sort_expr is not supported` —— 距离函数一旦被包住，向量索引就用不上。
- 漏写 `APPROXIMATE` 不报错，只是悄悄退化成全表精确扫描，数据量一大就慢得莫名其妙。
- `inner_product` 和 `l2_distance` 的排序方向相反，`ASC`/`DESC` 写错，结果看着「有值」但完全不对。
- 同一条连接里「建表 → 写入 → 近似查询」，查询返回空集且不报错；换条连接立刻能查到。
- `FULLTEXT ... WITH PARSER ik` 在官方镜像里会让写入卡到 `ERROR 4012` 查询超时。

以上都写进了 SKILL.md 的排查表，附实测报错原文。

## 内容

| 文件 | 用途 |
| --- | --- |
| `SKILL.md` | 主文件：起库、就绪判定、DDL、距离语义、混合检索、pyseekdb、调参、排查 |
| `examples/quickstart.sql` | 第一段：建库建表 + 写入 |
| `examples/queries.sql` | 第二段：检索验证（需另起一个连接，原因见 SKILL.md §3） |
| `examples/pyseekdb_demo.py` | 嵌入式与服务端两种 Python 用法 |

## 快速验证

```bash
docker run -d --name seekdb -p 2881:2881 -v seekdb_data:/var/lib/seekdb oceanbase/seekdb:latest
docker logs seekdb 2>&1 | grep -m1 "Seekdb started"

docker exec -i seekdb mysql -h127.0.0.1 -P2881 -uroot < examples/quickstart.sql
docker exec -i seekdb mysql -h127.0.0.1 -P2881 -uroot < examples/queries.sql
```

## 安装到 Agent

```bash
curl -fsSL https://modelscope.cn/skills/install.sh | bash -s -- Worigin/seekdb-vector
```

或直接把整个目录拷进 agent 的 skills 目录（如 `~/.agents/skills/`、`.claude/skills/`）。

## License

Apache-2.0
