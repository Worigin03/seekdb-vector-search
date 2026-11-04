-- seekdb 向量检索 · 第二段：检索验证
-- 必须在新连接里执行（先跑完 examples/quickstart.sql）。
--

USE demo;

-- 1) 近似检索：ORDER BY 里只放裸的距离函数，并带 APPROXIMATE。
--    期望：
--      1 -> 0
--      3 -> 0.141421374149721
--      2 -> 1.4142135623730951
SELECT id, title, l2_distance(embedding, '[1,0,0]') AS dist
FROM docs
ORDER BY dist APPROXIMATE
LIMIT 3;

-- 2) 标量过滤 + 向量排序，同一条 SQL 内完成。
--    期望：3, 2
SELECT id
FROM docs
WHERE id > 1
ORDER BY l2_distance(embedding, '[1,0,0]') APPROXIMATE
LIMIT 2;

-- 3) 余弦距离：同向为 0，正交为 1。
--    期望：1 -> 0，2 -> 1
SELECT id, cosine_distance(embedding, '[1,0,0]') AS d
FROM docs2
ORDER BY d APPROXIMATE
LIMIT 2;

-- 4) 内积：越大越相似，必须 DESC。
--    期望：1 -> 1，2 -> 0
SELECT id, inner_product(embedding, '[1,0,0]') AS s
FROM docs2
ORDER BY s DESC
LIMIT 2;

-- 5) 召回与延迟的开关（会话级，只影响当前连接）。
SHOW VARIABLES LIKE '%hnsw%';
SET ob_hnsw_ef_search = 128;
SELECT @@ob_hnsw_ef_search;

-- 6) 全文检索。
--    期望：1  quarterly report meeting
SELECT id, content
FROM articles
WHERE MATCH(content) AGAINST('report');

-- 7) 混合检索：全文条件先缩小候选集，再在候选集上做向量排序。
--    期望：只有命中 'report' 的 1 出现，dist = 0
SELECT id, content, cosine_distance(embedding, '[1,0,0]') AS dist
FROM articles
WHERE MATCH(content) AGAINST('report')
ORDER BY dist APPROXIMATE
LIMIT 10;

-- 8) 反例：距离函数被包住时索引直接不可用，会报
--    ERROR 1235 (0A000): Using vector index without vector_sort_expr is not supported
-- SELECT id FROM docs ORDER BY round(l2_distance(embedding, '[1,0,0]'), 6) APPROXIMATE LIMIT 3;
