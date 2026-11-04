-- seekdb 向量检索 · 第一段：建库、建表、写入
-- 用法：
--   docker exec -i seekdb mysql -h127.0.0.1 -P2881 -uroot < examples/quickstart.sql
-- 检索验证在 examples/queries.sql，必须在**另一条连接**里执行。
--
-- 注意：本脚本会 DROP 同名的 demo 库对象，只用于验证环境。

CREATE DATABASE IF NOT EXISTS demo;
USE demo;

DROP TABLE IF EXISTS docs;
DROP TABLE IF EXISTS docs2;
DROP TABLE IF EXISTS articles;

-- 1) 向量列 + HNSW 索引。DISTANCE 与 TYPE 必须同时给。
--    LIB / ORGANIZATION 可省，这里跟随官方示例写法。
CREATE TABLE docs (
  id        INT PRIMARY KEY,
  title     TEXT,
  embedding VECTOR(3),
  VECTOR INDEX idx_vec (embedding) WITH (DISTANCE=l2, TYPE=hnsw, LIB=vsag)
) ORGANIZATION = HEAP;

-- 2) 向量字面量是字符串，不是数组字面量
INSERT INTO docs VALUES
  (1, 'a', '[1,0,0]'),
  (2, 'b', '[0,1,0]'),
  (3, 'c', '[0.9,0.1,0]');

-- 3) 余弦距离的对照表
CREATE TABLE docs2 (
  id        INT PRIMARY KEY,
  embedding VECTOR(3),
  VECTOR INDEX idx2 (embedding) WITH (DISTANCE=cosine, TYPE=hnsw, LIB=vsag)
) ORGANIZATION = HEAP;

INSERT INTO docs2 VALUES (1, '[1,0,0]'), (2, '[0,1,0]');

-- 4) 混合检索的表：全文索引用默认分词器。
--    切勿写 WITH PARSER ik —— 官方镜像会卡到 ERROR 4012 查询超时。
CREATE TABLE articles (
  id        INT PRIMARY KEY,
  content   TEXT,
  embedding VECTOR(3),
  FULLTEXT  INDEX idx_fts (content),
  VECTOR    INDEX idx_vec (embedding) WITH (DISTANCE=cosine, TYPE=hnsw, LIB=vsag)
) ORGANIZATION = HEAP;

INSERT INTO articles VALUES
  (1, 'quarterly report meeting', '[1,0,0]'),
  (2, 'product launch notes',     '[0,1,0]');

-- 5) 索引参数的真实默认值
SHOW CREATE TABLE docs;
