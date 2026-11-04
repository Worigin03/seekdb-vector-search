"""pyseekdb 两种连接方式的完整示例。

依赖：
    pip install -U pyseekdb

服务端模式需先起库：
    docker run -d --name seekdb -p 2881:2881 -v seekdb_data:/var/lib/seekdb oceanbase/seekdb:latest

用法：
    python examples/pyseekdb_demo.py embedded   # 嵌入式，落盘到 ./seekdb
    python examples/pyseekdb_demo.py server     # 连 Docker 起的实例
"""

from __future__ import annotations

import sys

import pyseekdb
from pyseekdb import HNSWConfiguration

DIM = 8


def embedded() -> None:
    client = pyseekdb.Client(path="./seekdb", database="demo")
    col = client.get_or_create_collection(
        name="episodic",
        configuration=HNSWConfiguration(dimension=DIM, distance="cosine"),
        embedding_function=None,  # 自己给向量，不依赖默认嵌入模型
    )

    col.upsert(
        ids=["s1", "s2", "s3"],
        embeddings=[
            [1.0, 0, 0, 0, 0, 0, 0, 0],
            [0, 1.0, 0, 0, 0, 0, 0, 0],
            [0.9, 0.1, 0, 0, 0, 0, 0, 0],
        ],
        documents=["下周三去杭州出差", "周四评审会改到下午", "杭州酒店已订"],
        metadatas=[{"kind": "trip"}, {"kind": "meeting"}, {"kind": "trip"}],
    )

    hits = col.query(
        query_embeddings=[1.0, 0, 0, 0, 0, 0, 0, 0],
        n_results=2,
        include=["documents", "metadatas", "distances"],
    )

    # query() 返回「每个查询一组」：即使只查一条，也要取 [0]
    for doc_id, doc, dist in zip(hits["ids"][0], hits["documents"][0], hits["distances"][0]):
        print(f"{doc_id}\t{dist:.6f}\t{doc}")


def server() -> None:
    client = pyseekdb.Client(
        host="127.0.0.1",
        port=2881,
        database="demo",
        user="root",
        password="",  # 官方镜像默认空密码
    )

    col = client.get_or_create_collection(
        name="docs",
        configuration=HNSWConfiguration(dimension=DIM, distance="l2"),
        embedding_function=None,
    )

    col.add(
        ids=["d1", "d2"],
        embeddings=[[1.0, 0, 0, 0, 0, 0, 0, 0], [0, 1.0, 0, 0, 0, 0, 0, 0]],
        documents=["alpha", "beta"],
    )

    hits = col.query(query_embeddings=[1.0, 0, 0, 0, 0, 0, 0, 0], n_results=2)
    print(hits["ids"][0], hits["distances"][0])

    # 元数据过滤
    filtered = col.query(
        query_embeddings=[1.0, 0, 0, 0, 0, 0, 0, 0],
        where={"kind": {"$eq": "trip"}},
        n_results=5,
    )
    print(filtered["ids"][0])


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "embedded"
    {"embedded": embedded, "server": server}[mode]()
