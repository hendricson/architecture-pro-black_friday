## Задание 2. Шардирование

### Шаг 1: Запустить контейнеры
```bash
cd mongo-sharding
docker compose up -d
```

### Шаг 2: Инициализировать шардирование
```bash
chmod +x init-sharding.sh
./init-sharding.sh
```

### Шаг 3: Проверить работу
```bash
curl http://localhost:8080/
```

Количество документов в каждом из шардов (`collections.helloDoc.shards_count`) может отличаться, но в сумме должно получиться 1000:

```json
{
  "mongo_topology_type": "Sharded",
  "mongo_replicaset_name": null,
  "mongo_db": "somedb",
  "read_preference": "Primary()",
  "mongo_nodes": [
    [
      "mongos_router",
      27020
    ]
  ],
  "mongo_primary_host": null,
  "mongo_secondary_hosts": [],
  "mongo_is_primary": true,
  "mongo_is_mongos": true,
  "collections": {
    "helloDoc": {
      "documents_count": 1000,
      "shards_count": {
        "shard1": 521,
        "shard2": 479
      }
    }
  },
  "shards": {
    "shard1": "shard1/mongo-shard1:27018",
    "shard2": "shard2/mongo-shard2:27019"
  },
  "cache_enabled": false,
  "status": "OK"
}
```

### Доступные endpoints

| Метод | URL | Описание |
|-------|-----|----------|
| GET | `/` | Статус системы (шарды, топология) |
| GET | `/{collection}/count` | Количество документов в коллекции |
| GET | `/{collection}/users` | Список всех пользователей (до 1000) |
| GET | `/{collection}/users/{name}` | Получить пользователя по имени |
| POST | `/{collection}/users` | Создать нового пользователя |

Примеры:
```bash
curl http://localhost:8080/helloDoc/users
curl http://localhost:8080/helloDoc/users/user_42
curl http://localhost:8080/helloDoc/count
```

Остановка приложения:
```bash
docker compose down
```