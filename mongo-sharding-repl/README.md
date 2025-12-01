## Задание 3. Репликация

### Шаг 1: Запустить контейнеры
```bash
cd mongo-sharding-repl
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

Система работает на `http://localhost:8080/`

Количество документов в каждом из шардов (`collections.helloDoc.shards_count`) может отличаться, но в сумме должно получиться 1000. Также 
указано количество реплик в каждом шарде (`shards_replicas`).

```json
{
    "mongo_topology_type": "Sharded",
    "mongo_replicaset_name": null,
    "mongo_db": "somedb",
    "read_preference": "Primary()",
    "mongo_nodes": [
        [
            "mongos1",
            27026
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
                "shard2": 479,
                "shard1": 521
            }
        }
    },
    "shards": {
        "shard1": "shard1/shard1_primary:27020,shard1_secondary1:27021,shard1_secondary2:27022",
        "shard2": "shard2/shard2_primary:27023,shard2_secondary1:27024,shard2_secondary2:27025"
    },
    "shards_replicas": {
        "shard1": 3,
        "shard2": 3
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

### Доступные сервисы

| Сервис | URL |
|--------|-----|
| API | http://localhost:8080 |
| Mongos 1 | localhost:27026 |
| Mongos 2 | localhost:27027 |

### Остановка приложения
```bash
docker compose down
```