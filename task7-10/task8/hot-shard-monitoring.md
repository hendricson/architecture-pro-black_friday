# Задание 8. Выявление и устранение «горячих» шардов

## Проблема

Категория «Электроника» создаёт **70% нагрузки** на один шард, потому что:
- Hashed sharding по `_id` не учитывает паттерны доступа
- Популярные товары распределены случайно, но запросы к ним — нет
- Каталог фильтруется по `category`, что вызывает scatter-gather на все шарды

---

## 1. Метрики мониторинга шардов

### 1.1. Системные метрики (на каждом shard-сервере)

| Метрика | Команда / Источник | Порог предупреждения | Порог критический |
|---------|-------------------|---------------------|-------------------|
| CPU Usage | `top`, Prometheus node_exporter | > 70% | > 90% |
| Memory Usage | `free -m`, `db.serverStatus().mem` | > 80% | > 95% |
| Disk I/O Wait | `iostat`, `db.serverStatus().wiredTiger` | > 30% | > 50% |
| Disk Usage | `df -h` | > 70% | > 85% |
| Network In/Out | `iftop`, node_exporter | > 80% capacity | > 95% |

### 1.2. MongoDB-специфичные метрики

```javascript
// Выполнять на mongos или напрямую на шарде
db.serverStatus()
```

| Метрика | Путь в serverStatus | Что означает |
|---------|---------------------|--------------|
| Операции/сек | `opcounters.query`, `opcounters.update` | Нагрузка на шард |
| Активные соединения | `connections.current` | Количество клиентов |
| Queue length | `globalLock.currentQueue.readers/writers` | Очередь операций |
| Latency | `opLatencies.reads.latency`, `opLatencies.writes.latency` | Время ответа |
| Page faults | `extra_info.page_faults` | Нехватка RAM |
| Replication lag | `rs.status().members[].optimeDate` | Отставание реплик |

### 1.3. Метрики распределения данных

```javascript
// Распределение чанков по шардам
db.getSiblingDB("config").chunks.aggregate([
  { $match: { ns: "shop.products" } },
  { $group: { _id: "$shard", count: { $sum: 1 } } },
  { $sort: { count: -1 } }
])
```

| Метрика | Как получить | Порог дисбаланса |
|---------|--------------|------------------|
| Chunks per shard | `config.chunks` aggregate | Разница > 20% |
| Data size per shard | `db.collection.stats()` на каждом шарде | Разница > 30% |
| Jumbo chunks | `config.chunks.find({jumbo: true})` | Любые jumbo = проблема |

---

## 2. Выявление горячих шардов

### 2.1. Сравнение нагрузки между шардами

```javascript
// Выполнить на каждом шарде и сравнить
db.serverStatus().opcounters
// {
//   "insert": 1523,
//   "query": 892456,   ← если на одном шарде 892K, а на других 100K — hotspot
//   "update": 45123,
//   "delete": 234
// }
```

### 2.2. Анализ медленных запросов

```javascript
// Включить профилирование на шарде
db.setProfilingLevel(1, { slowms: 100 })

// Найти частые медленные запросы
db.system.profile.aggregate([
  { $match: { millis: { $gt: 100 } } },
  { $group: { 
      _id: "$ns", 
      count: { $sum: 1 },
      avgTime: { $avg: "$millis" }
  }},
  { $sort: { count: -1 } }
])
```

### 2.3. Скрипт диагностики горячего шарда

```javascript
// Запустить на mongos
function diagnoseHotShards(collectionName) {
  const chunks = db.getSiblingDB("config").chunks
    .aggregate([
      { $match: { ns: collectionName } },
      { $group: { _id: "$shard", chunks: { $sum: 1 } } }
    ]).toArray();
  
  print("=== Chunk Distribution ===");
  chunks.forEach(s => print(`${s._id}: ${s.chunks} chunks`));
  
  const jumbo = db.getSiblingDB("config").chunks
    .countDocuments({ ns: collectionName, jumbo: true });
  print(`\n=== Jumbo Chunks: ${jumbo} ===`);
  
  print("\n=== Check opcounters on each shard manually ===");
}

diagnoseHotShards("shop.products");
```

---

## 3. Механизмы устранения дисбаланса

### 3.1. Настройка балансировщика MongoDB

```javascript
// Проверить статус балансировщика
sh.getBalancerState()      // включён ли
sh.isBalancerRunning()     // работает ли сейчас

// Включить балансировщик (если выключен)
sh.startBalancer()

// Настроить окно балансировки (ночью, чтобы не мешать пользователям)
db.getSiblingDB("config").settings.updateOne(
  { _id: "balancer" },
  { $set: { 
      activeWindow: { start: "02:00", stop: "06:00" },
      _secondaryThrottle: true,  // ждать репликацию
      writeConcern: { w: "majority" }
  }},
  { upsert: true }
)
```

### 3.2. Ручное перемещение чанков

```javascript
// Найти чанки на перегруженном шарде
db.getSiblingDB("config").chunks.find({ 
  ns: "shop.products", 
  shard: "shard1" 
}).limit(5)

// Переместить чанк на другой шард
sh.moveChunk(
  "shop.products",
  { _id: MinKey },  // нижняя граница чанка
  "shard2"          // целевой шард
)
```

### 3.3. Разделение Jumbo-чанков

```javascript
// Найти jumbo-чанки
db.getSiblingDB("config").chunks.find({ 
  ns: "shop.products", 
  jumbo: true 
})

// Попробовать разделить (если возможно)
sh.splitAt("shop.products", { _id: ObjectId("середина_диапазона") })

// Или разделить посередине автоматически
sh.splitFind("shop.products", { _id: ObjectId("любой_id_в_чанке") })
```

---

## 4. Решение проблемы с категорией «Электроника»

### 4.1. Анализ проблемы

Текущий шард-ключ `{ _id: "hashed" }` не учитывает, что:
- 70% запросов фильтруют по `category: "electronics"`
- Товары электроники разбросаны по всем шардам
- Каждый запрос каталога → scatter-gather на все шарды

### 4.2. Вариант 1: Zone Sharding (Tag-Aware Sharding)

Выделить отдельный шард для популярной категории:

```javascript
// Добавить тег шарду
sh.addShardTag("shard1", "electronics")
sh.addShardTag("shard2", "other")
sh.addShardTag("shard3", "other")

// Привязать диапазон категории к тегу
// (требует изменения шард-ключа на {category: 1, _id: 1})
sh.addTagRange(
  "shop.products",
  { category: "electronics", _id: MinKey },
  { category: "electronics", _id: MaxKey },
  "electronics"
)

sh.addTagRange(
  "shop.products",
  { category: MinKey, _id: MinKey },
  { category: "electronics", _id: MinKey },
  "other"
)
```

**Преимущество:** Изоляция нагрузки — можно добавить мощный shard1 для электроники.

**Недостаток:** Требует resharding (изменение шард-ключа).

### 4.3. Вариант 2: Resharding на новый ключ

MongoDB 5.0+ поддерживает онлайн resharding:

```javascript
// Изменить шард-ключ с {_id: "hashed"} на {category: 1, _id: "hashed"}
db.adminCommand({
  reshardCollection: "shop.products",
  key: { category: 1, _id: "hashed" }
})

// Мониторинг прогресса
db.getSiblingDB("admin").aggregate([
  { $currentOp: { allUsers: true, localOps: false } },
  { $match: { type: "op", "originatingCommand.reshardCollection": { $exists: true } } }
])
```

**Новое распределение:**
```
Shard 1: category="electronics", _id hash 0-50%
Shard 2: category="electronics", _id hash 50-100%
Shard 3: category="books", "home", etc.
```

### 4.4. Вариант 3: Read Replicas для популярных запросов

Если resharding невозможен — масштабировать чтение через реплики:

```javascript
// Настроить приложение читать с secondary для каталога
db.products.find({ category: "electronics" })
  .readPref("secondaryPreferred")
  .readConcern("local")
```

И добавить больше secondary-нод в replica set перегруженного шарда.

---

## 5. Система алертинга

### 5.1. Prometheus + Alertmanager правила

```yaml
# prometheus-alerts.yml
groups:
  - name: mongodb-sharding
    rules:
      # Дисбаланс чанков
      - alert: ChunkImbalance
        expr: |
          max(mongodb_chunks_total) / min(mongodb_chunks_total) > 1.3
        for: 30m
        labels:
          severity: warning
        annotations:
          summary: "Chunk imbalance detected"
          description: "Shard chunk ratio > 1.3 for 30 minutes"

      # Высокая нагрузка на шард
      - alert: ShardHighLoad
        expr: |
          rate(mongodb_op_counters_total{type="query"}[5m]) > 10000
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "High query rate on shard {{ $labels.instance }}"

      # Очередь операций
      - alert: ShardQueueBacklog
        expr: |
          mongodb_global_lock_current_queue_total > 100
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Operation queue backlog on {{ $labels.instance }}"

      # Replication lag
      - alert: ReplicationLag
        expr: |
          mongodb_replset_member_replication_lag_seconds > 10
        for: 5m
        labels:
          severity: critical
```

## 6. Чек-лист реагирования на горячий шард

### Немедленные действия (< 1 часа)

- [ ] Определить горячий шард: `db.serverStatus().opcounters`
- [ ] Проверить jumbo-чанки: `config.chunks.find({jumbo: true})`
- [ ] Включить балансировщик: `sh.startBalancer()`
- [ ] Добавить secondary для read scaling (если возможно)
- [ ] Перенаправить read-трафик: `readPreference: secondaryPreferred`

### Краткосрочные действия (< 1 дня)

- [ ] Проанализировать паттерны запросов: `db.system.profile`
- [ ] Вручную переместить чанки: `sh.moveChunk()`
- [ ] Разделить jumbo-чанки: `sh.splitAt()`
- [ ] Добавить индексы для частых запросов
- [ ] Настроить окно балансировки на ночное время

### Долгосрочные действия (< 1 месяца)

- [ ] Пересмотреть шард-ключ для проблемной коллекции
- [ ] Выполнить resharding (MongoDB 5.0+)
- [ ] Настроить zone sharding для популярных категорий
- [ ] Внедрить мониторинг и алертинг
- [ ] Документировать процедуру реагирования

---

## 7. Сводная таблица метрик

| Категория | Метрика | Источник | Warning | Critical |
|-----------|---------|----------|---------|----------|
| **Система** | CPU | node_exporter | > 70% | > 90% |
| | Memory | node_exporter | > 80% | > 95% |
| | Disk I/O | iostat | > 30% | > 50% |
| **MongoDB** | Query rate | opcounters | 3x среднего | 5x среднего |
| | Write queue | globalLock | > 50 | > 100 |
| | Latency p99 | opLatencies | > 100ms | > 500ms |
| **Шардинг** | Chunk imbalance | config.chunks | > 20% разницы | > 50% разницы |
| | Jumbo chunks | config.chunks | > 0 | > 10 |
| | Balancer status | sh.getBalancerState | off > 1h | off > 24h |

