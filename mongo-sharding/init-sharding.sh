#!/bin/bash

# Инициализация MongoDB Sharded Cluster
# Этот скрипт настраивает:
# 1. Config Server (single instance replica set)
# 2. Shard 1 (single instance replica set)
# 3. Shard 2 (single instance replica set)
# 4. Mongos Router
# 5. Шардирование базы данных

set -e

echo "=========================================="
echo "Инициализация MongoDB Sharded Cluster"
echo "=========================================="

# Ждём, пока все контейнеры будут готовы
echo "Ожидание готовности контейнеров..."
sleep 15

# ============================================
# 1. Инициализация Config Server
# ============================================
echo ""
echo "1. Инициализация Config Server..."
docker compose exec -T configSrv mongosh --port 27017 --quiet <<EOF
rs.initiate(
  {
    _id: "config_server",
    configsvr: true,
    members: [
      { _id: 0, host: "configSrv:27017" }
    ]
  }
);
EOF
echo "✓ Config Server инициализирован"

# ============================================
# 2. Инициализация Shard 1
# ============================================
echo ""
echo "2. Инициализация Shard 1..."
docker compose exec -T mongo-shard1 mongosh --port 27018 --quiet <<EOF
rs.initiate(
  {
    _id: "shard1",
    members: [
      { _id: 0, host: "mongo-shard1:27018" }
    ]
  }
);
EOF
echo "✓ Shard 1 инициализирован"

# ============================================
# 3. Инициализация Shard 2
# ============================================
echo ""
echo "3. Инициализация Shard 2..."
docker compose exec -T mongo-shard2 mongosh --port 27019 --quiet <<EOF
rs.initiate(
  {
    _id: "shard2",
    members: [
      { _id: 0, host: "mongo-shard2:27019" }
    ]
  }
);
EOF
echo "✓ Shard 2 инициализирован"

# Ждём, пока шарды будут готовы
echo ""
echo "Ожидание готовности шардов..."
sleep 10

# ============================================
# 4. Добавление шардов в Mongos
# ============================================
echo ""
echo "4. Добавление шардов в mongos_router..."
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
sh.addShard("shard1/mongo-shard1:27018");
sh.addShard("shard2/mongo-shard2:27019");
EOF
echo "✓ Шарды добавлены"

# ============================================
# 5. Включение шардирования для БД
# ============================================
echo ""
echo "5. Включение шардирования для БД somedb..."
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
sh.enableSharding("somedb");
sh.shardCollection("somedb.helloDoc", { "_id": "hashed" });
EOF
echo "✓ Шардирование включено"

# ============================================
# 6. Вставка тестовых данных
# ============================================
echo ""
echo "6. Вставка 1000 тестовых документов..."
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
use somedb;
for(var i = 0; i < 1000; i++) {
  db.helloDoc.insert({
    _id: i,
    age: i,
    name: "user_" + i,
    email: "user_" + i + "@example.com"
  });
}
EOF
echo "✓ Тестовые данные вставлены"

# ============================================
# 7. Проверка распределения данных
# ============================================
echo ""
echo "7. Проверка распределения данных..."
echo ""
echo "Всего документов в somedb.helloDoc:"
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
use somedb;
db.helloDoc.countDocuments();
EOF

echo ""
echo "Документов в mongo-shard1:"
docker compose exec -T mongo-shard1 mongosh --port 27018 --quiet <<EOF
use somedb;
db.helloDoc.countDocuments();
EOF

echo ""
echo "Документов в mongo-shard2:"
docker compose exec -T mongo-shard2 mongosh --port 27019 --quiet <<EOF
use somedb;
db.helloDoc.countDocuments();
EOF

echo ""
echo "=========================================="
echo "✓ Инициализация завершена успешно!"
echo "=========================================="
echo ""
echo "Доступные endpoints:"
echo "  - API: http://localhost:8080"
echo "  - mongos_router: localhost:27020"
echo ""

