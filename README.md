# Высоконагруженный интернет-магазин «Мобильный мир»

Демо-проект: MongoDB sharding + репликация + Redis cache.

## Запуск системы

### Шаг 1: Запустить контейнеры

```bash
cd sharding-repl-cache
docker compose up -d
```

### Шаг 2: Инициализировать шардирование

```bash
# Можно подождать пока всё поднимется
sleep 30
chmod +x init-sharding.sh
./init-sharding.sh
```

### Шаг 3: Проверить работу

```bash
curl http://localhost:8080/
```

Ответ системы:
```json
{
    "mongo_topology_type": "Sharded",
    "mongo_db": "somedb",
    "collections": {
        "helloDoc": {
            "documents_count": 1000,
            "shards_count": {
                "shard1": 521,
                "shard2": 479
            }
        }
    },
    "shards_replicas": {
        "shard1": 3,
        "shard2": 3
    },
    "cache_enabled": true,
    "status": "OK"
}
```

---

## Проверка кеширования

Первый запрос (без кеша):
```bash
curl -w "Time: %{time_total}s\n" -o /dev/null -s http://localhost:8080/helloDoc/users
# Time: 1.015077s
```

Повторный запрос (из кеша):
```bash
curl -w "Time: %{time_total}s\n" -o /dev/null -s http://localhost:8080/helloDoc/users
# Time: 0.073378s
```

---

## Доступные endpoints

| Метод | URL | Описание |
|-------|-----|----------|
| GET | `/` | Статус системы (шарды, топология) |
| GET | `/{collection}/count` | Количество документов в коллекции |
| GET | `/{collection}/users` | Список пользователей (**кешируется**) |
| GET | `/{collection}/users/{name}` | Получить пользователя по имени |
| POST | `/{collection}/users` | Создать нового пользователя |

Примеры:
```bash
curl http://localhost:8080/helloDoc/users
curl http://localhost:8080/helloDoc/users/user_42
curl http://localhost:8080/helloDoc/count
```

Swagger: http://localhost:8080/docs

---

## Доступные сервисы

| Сервис | URL |
|--------|-----|
| API | http://localhost:8080 |
| Mongos 1 | localhost:27026 |
| Mongos 2 | localhost:27027 |
| Redis Master | localhost:6379 |
| Redis Replica | localhost:6380 |

---

## Остановка

```bash
cd sharding-repl-cache
docker compose down
```

---

## Документация

Архитектурные решения описаны в [task7-10/architecture.md](task7-10/architecture.md):
- Структуры данных MongoDB и Cassandra
- Выбор shard-ключей и partition keys
- Мониторинг и устранение горячих шардов
- Стратегии чтения с реплик
- Метрики и алертинг