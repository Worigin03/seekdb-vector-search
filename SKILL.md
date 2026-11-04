---
name: seekdb-vector
description: 用 seekdb（OceanBase 出品的轻量级 AI 数据库）搭向量检索 / 语义搜索 / RAG 检索层时使用。覆盖 Docker 起库与就绪判定、VECTOR 表与 HNSW 索引 DDL、l2 / cosine / inner_product 三种距离的近似检索、向量 + 全文混合查询、pyseekdb 读写集合，以及「索引不生效」「连不上」「查询超时」的排查。
license: Apache-2.0
---

# seekdb 向量检索

一句话定位：**一条 SQL 同时拿到「向量相似度 + 全文匹配 + 标量过滤」**，不用再单独部署一套向量库。

本文件里的 DDL / DML / 返回值都在 `oceanbase/seekdb:latest`（`seekdb-v1.4.0.0`，MySQL 协议端口 2881）上实跑过。标了「实测」的输出是真实返回，不是示意。

---

## 0. 先选形态，再动手

| 你的情况 | 选这个 | 代价 |
| --- | --- | --- |
| 要 SQL、要多进程/多语言共享同一份数据 | Docker 起 `oceanbase/seekdb:latest` | 一条 `docker run` |
| 纯 Python、单进程、不想管端口 | `pip install -U pyseekdb` 嵌入式 | 无服务端 |
| 已有 MySQL 生态（SQLAlchemy / pymysql / Dify / LangChain） | 上面任选一个，走 MySQL 协议 | — |

只在 Python 里用、且不需要跨进程读同一份数据时，**不要先起容器**，嵌入式 pyseekdb 更省事。

---

## 1. Docker 起库

```bash
docker run -d --name seekdb \
  -p 2881:2881 \
  -v seekdb_data:/var/lib/seekdb \
  oceanbase/seekdb:latest
```

三个必须记住的点：

1. `2881` 是 MySQL 协议端口，是唯一必须先映射的端口。
2. root **默认空密码**，日志里会明写 `ROOT_PASSWORD is empty; leaving root password unset.`。生产环境请自己设密码。
3. 数据目录 `/var/lib/seekdb`，**必须挂卷**；不挂的话 `docker rm` 之后库和实例一起消失。

### 就绪判定

镜像没有内置 healthcheck，`docker ps` 显示 `Up` 时 SQL 端口可能还没开。等日志里这一行：

```bash
docker logs seekdb 2>&1 | grep -m1 "Seekdb started" && echo ready
```

首次启动的日志顺序是固定的（本机实测 5 秒内走完）：

```
Fresh instance: waiting for empty-password SQL readiness...
SeekDB SQL ready (empty password) on attempt #5.
ROOT_PASSWORD is empty; leaving root password unset.
Initialization complete.
Seekdb started
```

`attempt #N` 只是空密码探测的重试序号，不是报错，不用管。

### 连通性自检

```bash
docker exec seekdb mysql -h127.0.0.1 -P2881 -uroot -e "select version();"
```

实测输出：

```
version()
5.7.25-OceanBase seekdb-v1.4.0.0
```

宿主机装了 mysql 客户端就去掉 `docker exec seekdb`，直接 `-h127.0.0.1 -P2881`。Windows 上用 `docker exec` 免装客户端最省事。

---

## 2. 建向量表（DDL）

```sql
CREATE DATABASE IF NOT EXISTS demo;
USE demo;

CREATE TABLE docs (
  id        INT PRIMARY KEY,
  title     TEXT,
  embedding VECTOR(3),
  VECTOR INDEX idx_vec (embedding) WITH (DISTANCE=l2, TYPE=hnsw, LIB=vsag)
) ORGANIZATION = HEAP;
```

三段配置各自都不能省，少一个就报到下一步：

| 片段 | 是否必须（实测） |
| --- | --- |
| `WITH (DISTANCE=..., TYPE=hnsw)` | **必须**。缺任一项就报 `ERROR 1235: vector index params not set distance and type is not supported` |
| `LIB=vsag` | 可选，不写用默认向量库；官方示例统一写 `vsag`，跟随即可 |
| `ORGANIZATION = HEAP` | 可选，不写默认落成 `ORGANIZATION INDEX`，建表和 `APPROXIMATE` 查询都正常；官方 README 写 `HEAP`，跟随即可 |

- `VECTOR(N)` 的 N 必须和你的 embedding 维度**完全一致**，写 384 就永远只能塞 384 维向量。
- `DISTANCE` 取值：`l2`、`cosine`、`inner_product`。选错不会报错，只会让排序结果错得很难发现——建表前先确认你的向量是怎么归一化的。

---

## 3. 写入与近似检索

```sql
INSERT INTO docs VALUES
  (1, 'a', '[1,0,0]'),
  (2, 'b', '[0,1,0]'),
  (3, 'c', '[0.9,0.1,0]');

SELECT id, title, l2_distance(embedding, '[1,0,0]') AS dist
FROM docs
ORDER BY dist APPROXIMATE
LIMIT 3;
```

实测输出（`l2` 索引）：

```
id  title  dist
1   a      0
3   c      0.141421374149721
2   b      1.4142135623730951
```

### 四个必须记住的约束

1. **向量字面量是字符串**：`'[1,0,0]'`，不是 `[1,0,0]`，也不是逗号分隔的 `1,0,0`。
2. **`APPROXIMATE` 是命中 HNSW 索引的开关**。不写也能跑（实测返回同样的 top-2），但走的是精确逐行计算；上了百万行就是全表扫描，慢到你以为索引坏了。
3. **`ORDER BY` 里的表达式只能是裸的距离函数**。`ORDER BY round(l2_distance(...), 6) APPROXIMATE` 会直接报：

   ```
   ERROR 1235 (0A000): Using vector index without vector_sort_expr is not supported
   ```

   要格式化就先用别名算出 `dist`，外层再处理；不要包在 `ORDER BY` 里。

4. **刚写入的数据，在同一条连接里做 `APPROXIMATE` 查询查不到——不报错，返回空集。**

   实测复现：同一条 `mysql` 连接里依次执行 `CREATE TABLE` → `INSERT` → `SELECT ... ORDER BY ... APPROXIMATE`，结果是 `Empty set`；换一条新连接再跑同样的 SELECT，三行全在。别把脚本写在同一个 session 里就断定「数据没写进去」——先开新连接确认，再怀疑写入。

   写脚本/做 demo 时把「建表 + 写入」和「向量检索」拆成两段、两次连接执行，否则第一次跑必然是空结果。

### 距离函数语义

| 函数 | 越小越近？ | `ORDER BY` | 取值含义（实测） |
| --- | --- | --- | --- |
| `l2_distance(a, b)` | 是 | `ASC`（默认） | 欧氏距离，同向量为 0 |
| `cosine_distance(a, b)` | 是 | `ASC`（默认） | `1 - 余弦相似度`，同向为 0，正交为 1 |
| `inner_product(a, b)` | 否 | **`DESC`** | 内积，越大越相似 |

`cosine_distance` 实测：`[1,0,0]` 对 `[1,0,0]` 得 `0`，对 `[0,1,0]` 得 `1`。所以**不要**按「距离越小越好」去解释内积的结果，`inner_product` 必须配 `DESC`。

### 带标量过滤的近似检索

```sql
SELECT id FROM docs
WHERE id > 1
ORDER BY l2_distance(embedding, '[1,0,0]') APPROXIMATE
LIMIT 2;
```

实测返回 `3, 2`——过滤条件与向量索引可以同时生效，不需要先在应用层筛一遍 ID 再回查。

---

## 4. 混合检索（向量 + 全文）

```sql
CREATE TABLE articles (
  id        INT PRIMARY KEY,
  content   TEXT,
  embedding VECTOR(384),
  FULLTEXT  INDEX idx_fts (content),
  VECTOR    INDEX idx_vec (embedding) WITH (DISTANCE=cosine, TYPE=hnsw, LIB=vsag)
) ORGANIZATION = HEAP;

SELECT id, cosine_distance(embedding, '[...]') AS dist
FROM articles
WHERE MATCH(content) AGAINST('quarterly report')
ORDER BY dist APPROXIMATE
LIMIT 10;
```

`MATCH ... AGAINST` 与向量排序可以写在同一条 SQL 里：先由全文索引把候选集缩小，再在候选集上算向量距离，省掉一次应用层的 ID 回传。

实测（表内 `1 = quarterly report meeting`、`2 = product launch notes`）：

```
id  content                    dist
1   quarterly report meeting   0
```

只有命中全文条件的行参与向量排序，`2` 没有出现——过滤是在向量检索之前生效的。

**分词器有个坑（实测）**：`FULLTEXT INDEX ... WITH PARSER ik` 在该镜像里建表能过，但随后的写入和查询会一直卡到查询超时：

```
ERROR 4012 (HY000): Timeout, query has reached the maximum query timeout: 10000000(us)
```

换成默认分词器（`FULLTEXT INDEX idx_fts (content)`）则英文检索正常。需要中文分词时，先确认镜像里装了 ik 插件，否则改用默认分词器 + 应用侧提取关键词。

---

## 5. Python：pyseekdb

### 嵌入式（无服务端）

```python
import pyseekdb

client = pyseekdb.Client(path="./seekdb", database="demo")
col = client.get_or_create_collection(name="episodic")

col.upsert(ids=["s1"], documents=["用户说下周三去杭州出差"])
hits = col.query(query_texts=["出差安排"], n_results=5)
```

`documents` 不给 `embeddings` 时，集合会用 `embedding_function` 自动算向量（默认 `DefaultEmbeddingFunction()`，384 维）。要自己控制向量就把 `embeddings=` 一起传，并把集合建成 `embedding_function=None`。

### 连 Docker 起的服务端

```python
import pyseekdb
from pyseekdb import HNSWConfiguration

client = pyseekdb.Client(
    host="127.0.0.1", port=2881,
    database="demo", user="root", password="",   # 默认空密码
)

col = client.create_collection(
    name="docs",
    configuration=HNSWConfiguration(dimension=384, distance="cosine"),
    embedding_function=None,      # 自己传向量
)
```

- `configuration` 不传时默认 `dimension=384, distance="cosine"`，**必须和你实际传入的向量维度一致**。
- `query()` 返回 chromadb 兼容结构：`ids` / `documents` / `metadatas` / `distances`，都是「每个查询一组」的二维列表——单条查询也要取 `[0]`。
- 元数据过滤用 `where={"category": {"$eq": "AI"}}`。

---

## 6. 调召回与延迟：三层参数

### 索引级（建表时写进 `WITH`，对整张表长期生效）

```sql
VECTOR INDEX idx_vec (embedding)
  WITH (DISTANCE=cosine, TYPE=hnsw, LIB=vsag,
        M=32, EF_CONSTRUCTION=400, EF_SEARCH=128)
```

三个参数的真实默认值不用猜，`SHOW CREATE TABLE` 会直接告诉你（实测）：

```sql
SHOW CREATE TABLE docs;
-- VECTOR KEY `idx_vec` (`embedding`)
--   WITH (DISTANCE=L2, TYPE=HNSW, LIB=VSAG, M=16, EF_CONSTRUCTION=200, EF_SEARCH=64)
```

| 参数 | 默认 | 调大的代价 | 什么时候调 |
| --- | --- | --- | --- |
| `M` | 16 | 内存占用和建索引时间上去了 | 向量维度高、数据分布复杂、召回不够 |
| `EF_CONSTRUCTION` | 200 | 建索引更慢，查询不变 | 只影响索引质量，导入期可以放宽 |
| `EF_SEARCH` | 64 | 每次查询更慢 | 该出现的结果没出现时优先调它 |

### 会话级（不改表，只影响当前连接）

```sql
SHOW VARIABLES LIKE '%hnsw%';
-- ob_hnsw_ef_search            64
-- ob_hnsw_extra_info_max_size  1024

SET ob_hnsw_ef_search = 128;    -- 实测立即生效
```

**临时验证就调这个，别去改表**：默认 64 适合「top-10 + 数据量不大」；怀疑召回问题时先 `SET` 到 128/256 重跑同一条 SQL，如果结果补齐了就是 `ef_search` 太小，再决定要不要落到索引参数上。

### 精确 vs 近似

不写 `APPROXIMATE` 时走精确计算（结果一定对，但没有索引加速）。数据量小的时候两者结果一样，**只在结果对不上时才值得怀疑索引**——先切精确模式跑一遍做基线，再切回近似对比。

---

## 7. 故障排查

| 现象 | 真正原因 | 处理 |
| --- | --- | --- |
| 刚插入的行 `APPROXIMATE` 查不到，返回空集且不报错 | 同一条连接里「建表 → 写入 → 索引查询」，索引层还看不到本会话刚写的行 | 换新连接再查；脚本把写入和检索拆成两次执行 |
| `ERROR 1045 Access denied for user 'root'` | 连到了**别人**的实例（比如 Compose 起的、设过密码的） | 确认端口对应的容器：`docker port <name>`；空密码只对新建的官方镜像成立 |
| 容器 `Up` 但连不上 | SQL 端口还没开 | 等日志出现 `Seekdb started` |
| `ERROR 1235 vector index params not set distance and type` | `WITH` 里缺 `DISTANCE` 或 `TYPE` | 两个都写 |
| `ERROR 1235 Using vector index without vector_sort_expr` | `ORDER BY` 里包了函数（`round`/`abs`/算术） | `ORDER BY` 只放裸距离函数 + `APPROXIMATE` |
| 查询很慢 | 漏了 `APPROXIMATE`，走了全表精确计算 | 补 `APPROXIMATE` |
| 结果排序看起来是反的 | `inner_product` 配了 `ASC` | 内积用 `DESC` |
| 结果缺了明显该有的行 | `ef_search` 太小 | `SET ob_hnsw_ef_search = 128` |
| 写入/查询卡 10 秒后 `4012` | 全文索引用了 `WITH PARSER ik`，插件不在镜像里 | 去掉 parser 或换默认分词 |
| 重启后数据没了 | 没挂 `/var/lib/seekdb` 卷 | 重建并挂卷；已丢的数据无法恢复 |

---

## 8. 交付前自检

- [ ] `VECTOR(N)` 的 N == 实际传入向量维度？
- [ ] `DISTANCE` 和向量归一化方式匹配（归一化过 → `cosine` 或 `inner_product`）？
- [ ] 每条向量查询都写了 `APPROXIMATE`？
- [ ] `ORDER BY` 里是裸距离函数，没有包 `round()`？
- [ ] `inner_product` 用的是 `DESC`？
- [ ] 数据卷挂到了 `/var/lib/seekdb`？
- [ ] 连接串里的密码和实例实际状态一致（新建镜像为空密码）？

---

## 9. 最小可跑示例

完整可执行版本见 `examples/`：`quickstart.sql`（建库建表写入）、`queries.sql`（检索验证，需换个连接跑）、`pyseekdb_demo.py`（Python）。

```bash
docker run -d --name seekdb -p 2881:2881 -v seekdb_data:/var/lib/seekdb oceanbase/seekdb:latest
docker logs seekdb 2>&1 | grep -m1 "Seekdb started"

# 第一段：建表 + 写入
docker exec -i seekdb mysql -h127.0.0.1 -P2881 -uroot < examples/quickstart.sql

# 第二段：另起一个连接做检索（同一条连接里刚写完就查会返回空集）
docker exec -i seekdb mysql -h127.0.0.1 -P2881 -uroot < examples/queries.sql
```

<!-- OB-S:H1Yi4QvF9STopfAMpT-Spg -->
