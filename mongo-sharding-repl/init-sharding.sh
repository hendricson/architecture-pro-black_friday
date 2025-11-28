#!/bin/bash

# Инициализация MongoDB Sharded Cluster
# Этот скрипт настраивает:
# 1. Config Servers Replica Set
# 2. Shard 1 Replica Set
# 3. Shard 2 Replica Set
# 4. Mongos Routers
# 5. Шардирование базы данных

set -e

echo "=========================================="
echo "Инициализация MongoDB Sharded Cluster"
echo "=========================================="

# Ждём, пока все контейнеры будут готовы
echo "Ожидание готовности контейнеров..."
sleep 15

# ============================================
# 1. Инициализация Config Servers
# ============================================
echo ""
echo "1. Инициализация Config Servers Replica Set..."
docker compose exec -T config1 mongosh --port 27017 --quiet <<EOF
rs.initiate(
  {
    _id: "config_server",
    configsvr: true,
    members: [
      { _id: 0, host: "config1:27017" },
      { _id: 1, host: "config2:27018" },
      { _id: 2, host: "config3:27019" }
    ]
  }
);
EOF
echo "✓ Config Servers инициализированы"

# ============================================
# 2. Инициализация Shard 1
# ============================================
echo ""
echo "2. Инициализация Shard 1 Replica Set..."
docker compose exec -T shard1_primary mongosh --port 27020 --quiet <<EOF
rs.initiate(
  {
    _id: "shard1",
    members: [
      { _id: 0, host: "shard1_primary:27020" },
      { _id: 1, host: "shard1_secondary1:27021" },
      { _id: 2, host: "shard1_secondary2:27022" }
    ]
  }
);
EOF
echo "✓ Shard 1 инициализирован"

# ============================================
# 3. Инициализация Shard 2
# ============================================
echo ""
echo "3. Инициализация Shard 2 Replica Set..."
docker compose exec -T shard2_primary mongosh --port 27023 --quiet <<EOF
rs.initiate(
  {
    _id: "shard2",
    members: [
      { _id: 0, host: "shard2_primary:27023" },
      { _id: 1, host: "shard2_secondary1:27024" },
      { _id: 2, host: "shard2_secondary2:27025" }
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
echo "4. Добавление шардов в Mongos..."
docker compose exec -T mongos1 mongosh --port 27026 --quiet <<EOF
sh.addShard("shard1/shard1_primary:27020,shard1_secondary1:27021,shard1_secondary2:27022");
sh.addShard("shard2/shard2_primary:27023,shard2_secondary1:27024,shard2_secondary2:27025");
EOF
echo "✓ Шарды добавлены"

# ============================================
# 5. Включение шардирования для БД
# ============================================
echo ""
echo "5. Включение шардирования для БД somedb..."
docker compose exec -T mongos1 mongosh --port 27026 --quiet <<EOF
sh.enableSharding("somedb");
sh.shardCollection("somedb.helloDoc", { "_id": "hashed" });
EOF
echo "✓ Шардирование включено"

# ============================================
# 6. Вставка тестовых данных
# ============================================
echo ""
echo "6. Вставка 1000 тестовых документов..."
docker compose exec -T mongos1 mongosh --port 27026 --quiet <<EOF
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
docker compose exec -T mongos1 mongosh --port 27026 --quiet <<EOF
use somedb;
db.helloDoc.countDocuments();
EOF

echo ""
echo "Документов в Shard 1:"
docker compose exec -T shard1_primary mongosh --port 27020 --quiet <<EOF
use somedb;
db.helloDoc.countDocuments();
EOF

echo ""
echo "Документов в Shard 2:"
docker compose exec -T shard2_primary mongosh --port 27023 --quiet <<EOF
use somedb;
db.helloDoc.countDocuments();
EOF

echo ""
echo "=========================================="
echo "✓ Инициализация завершена успешно!"
echo "=========================================="
echo ""
echo "Доступные endpoints:"
echo "  - API (Load Balancer): http://localhost:8080"
echo "  - API Instance 1: http://localhost:8081"
echo "  - API Instance 2: http://localhost:8082"
echo "  - API Instance 3: http://localhost:8083"
echo "  - Mongos 1: localhost:27026"
echo "  - Mongos 2: localhost:27027"
echo ""

