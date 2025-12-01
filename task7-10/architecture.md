# Архитектура данных интернет-магазина «Мобильный мир»

## Содержание

1. [Обзор системы](#1-обзор-системы)
2. [Структуры данных MongoDB](#2-структуры-данных-mongodb)
3. [Шардирование MongoDB](#3-шардирование-mongodb)
4. [Мониторинг и устранение горячих шардов](#4-мониторинг-и-устранение-горячих-шардов)
5. [Чтение с реплик](#5-чтение-с-реплик)
6. [Миграция на Cassandra](#6-миграция-на-cassandra)
7. [Структуры данных Cassandra](#7-структуры-данных-cassandra)
8. [Стратегии целостности данных Cassandra](#8-стратегии-целостности-данных-cassandra)
9. [Сравнение масштабирования](#9-сравнение-масштабирования)
10. [Метрики мониторинга](#10-метрики-мониторинга)

---

## 1. Обзор системы

Онлайн-магазин «Мобильный мир» использует гибридную архитектуру:

| База данных | Назначение | Данные |
|-------------|------------|--------|
| **MongoDB** | Транзакции, сложные запросы | Активные заказы, каталог товаров, остатки на складе |
| **Cassandra** | Высокая частота записи, гео-распределение | Сессии, корзины, история заказов |

### Обоснование выбора

**MongoDB** используется для данных, требующих:
- Strong consistency (остатки на складе — риск overselling)
- ACID-транзакции (активные заказы, платежи)
- Сложные запросы с фильтрами (каталог товаров)

**Cassandra** используется для данных, где:
- Высокая частота записи (сессии обновляются при каждом запросе)
- Eventual consistency допустима (история заказов не меняется)
- Требуется гео-распределение (сессии доступны в любом регионе)
- Линейное масштабирование без resharding (Black Friday: 50 000 req/s)

---

## 2. Структуры данных MongoDB

### 2.1. Коллекция `orders`

```javascript
{
  _id: ObjectId("..."),
  customer_id: ObjectId("user_123"),
  created_at: ISODate("2024-11-29T10:30:00Z"),
  items: [
    { product_id: ObjectId("prod_1"), name: "Смартфон X", quantity: 1, price: 49990 },
    { product_id: ObjectId("prod_2"), name: "Чехол", quantity: 2, price: 990 }
  ],
  status: "delivered",  // "pending" | "paid" | "shipped" | "delivered" | "cancelled"
  total_amount: 51970,
  geo_zone: "moscow"
}
```

### 2.2. Коллекция `products`

```javascript
{
  _id: ObjectId("..."),
  name: "Смартфон X",
  category: "electronics",
  price: 49990,
  stock: {
    "moscow": 150,
    "spb": 80,
    "ekb": 50
  },
  attributes: {
    color: "black",
    storage: "128GB",
    brand: "BrandX"
  },
  created_at: ISODate("2024-01-15T00:00:00Z"),
  updated_at: ISODate("2024-11-29T12:00:00Z")
}
```

### 2.3. Коллекция `carts`

```javascript
{
  _id: ObjectId("..."),
  user_id: ObjectId("user_123"),  // null для гостей
  session_id: "sess_abc123",      // всегда генерируется
  items: [
    { product_id: ObjectId("prod_1"), quantity: 2 },
    { product_id: ObjectId("prod_2"), quantity: 1 }
  ],
  status: "active",  // "active" | "ordered" | "abandoned"
  created_at: ISODate("2024-11-29T10:00:00Z"),
  updated_at: ISODate("2024-11-29T10:30:00Z"),
  expires_at: ISODate("2024-12-06T10:00:00Z")  // TTL: 7 дней
}
```

---

## 3. Шардирование MongoDB

### 3.1. Сводная таблица шард-ключей

| Коллекция | Шард-ключ | Стратегия | Основной паттерн запросов |
|-----------|-----------|-----------|---------------------------|
| `orders` | `{customer_id: 1, _id: 1}` | Range | История заказов клиента |
| `products` | `{_id: "hashed"}` | Hashed | Страница товара, обновление stock |
| `carts` | `{session_id: 1, _id: 1}` | Range | Получение активной корзины |

### 3.2. Обоснование выбора

#### orders: `{customer_id: 1, _id: 1}`

| Критерий | Почему подходит |
|----------|-----------------|
| Изоляция запросов | Все заказы клиента на одном шарде → targeted query |
| Кардинальность | Составной ключ даёт уникальность |
| Равномерность | `_id` предотвращает hotspot на активных клиентах |

#### products: `{_id: "hashed"}`

| Критерий | Почему подходит |
|----------|-----------------|
| Равномерное распределение | Hashed `_id` даёт идеальное распределение |
| Частые обновления stock | Запись распределена, нет hotspot |
| Страница товара | `findOne({_id: X})` → targeted query |

#### carts: `{session_id: 1, _id: 1}`

| Критерий | Почему подходит |
|----------|-----------------|
| Гостевые корзины | `session_id` есть у всех корзин |
| Targeted queries | `find({session_id: X})` → один шард |
| TTL очистка | Работает корректно |

### 3.3. Команды настройки

```javascript
sh.enableSharding("shop")
sh.shardCollection("shop.orders", { customer_id: 1, _id: 1 })
sh.shardCollection("shop.products", { _id: "hashed" })
sh.shardCollection("shop.carts", { session_id: 1, _id: 1 })
```

### 3.4. Индексы

```javascript
// orders
db.orders.createIndex({ status: 1, created_at: -1 })
db.orders.createIndex({ geo_zone: 1, created_at: -1 })

// products
db.products.createIndex({ category: 1, price: 1 })
db.products.createIndex({ "attributes.brand": 1, category: 1 })

// carts
db.carts.createIndex({ user_id: 1, status: 1 })
db.carts.createIndex({ expires_at: 1 }, { expireAfterSeconds: 0 })
```

---

## 4. Мониторинг и устранение горячих шардов

### 4.1. Проблема

Категория «Электроника» создаёт 70% нагрузки на один шард:
- Hashed sharding по `_id` не учитывает паттерны доступа
- Каждый запрос каталога по категории → scatter-gather на все шарды

### 4.2. Метрики мониторинга

| Категория | Метрика | Источник | Warning | Critical |
|-----------|---------|----------|---------|----------|
| Система | CPU | node_exporter | > 70% | > 90% |
| Система | Memory | node_exporter | > 80% | > 95% |
| MongoDB | Query rate | `db.serverStatus().opcounters` | 3× среднего | 5× среднего |
| MongoDB | Write queue | `globalLock.currentQueue` | > 50 | > 100 |
| MongoDB | Latency p99 | `opLatencies` | > 100ms | > 500ms |
| Шардинг | Chunk imbalance | `config.chunks` | > 20% | > 50% |
| Шардинг | Jumbo chunks | `config.chunks` | > 0 | > 10 |

### 4.3. Выявление горячего шарда

```javascript
// Сравнение нагрузки между шардами
db.serverStatus().opcounters
// Если на одном шарде 892K queries, а на других 100K — hotspot

// Распределение чанков
db.getSiblingDB("config").chunks.aggregate([
  { $match: { ns: "shop.products" } },
  { $group: { _id: "$shard", count: { $sum: 1 } } }
])

// Jumbo-чанки
db.getSiblingDB("config").chunks.find({ ns: "shop.products", jumbo: true })
```

### 4.4. Механизмы устранения

**Настройка балансировщика:**
```javascript
sh.startBalancer()
db.getSiblingDB("config").settings.updateOne(
  { _id: "balancer" },
  { $set: { activeWindow: { start: "02:00", stop: "06:00" } } },
  { upsert: true }
)
```

**Ручное перемещение чанков:**
```javascript
sh.moveChunk("shop.products", { _id: MinKey }, "shard2")
```

**Resharding (MongoDB 5.0+):**
```javascript
db.adminCommand({
  reshardCollection: "shop.products",
  key: { category: 1, _id: "hashed" }
})
```

### 4.5. Чек-лист реагирования

| Срок | Действия |
|------|----------|
| < 1 часа | Включить балансировщик, перенаправить read на secondary |
| < 1 дня | Переместить чанки, разделить jumbo-чанки, добавить индексы |
| < 1 месяца | Resharding, zone sharding, внедрить мониторинг |

---

## 5. Чтение с реплик

### 5.1. Таблица операций чтения

| Коллекция | Операция | Read Preference | Допустимый lag |
|-----------|----------|-----------------|----------------|
| `products` | Просмотр каталога | `secondaryPreferred` | до 5 сек |
| `products` | Проверка stock | `primary` | 0 |
| `orders` | История заказов | `secondaryPreferred` | до 30 сек |
| `orders` | Статус текущего заказа | `primary` | 0 |
| `carts` | Все операции | `primary` | 0 |

### 5.2. Категории задержки

| Категория | Допустимый lag | Примеры |
|-----------|----------------|---------|
| Real-time | 0 (primary) | Покупка, резерв stock, корзина |
| Near real-time | до 2 сек | Статус заказа для support |
| Eventually consistent | до 30 сек | История заказов, каталог |
| Batch | до 5-60 мин | Отчёты, аналитика |

### 5.3. Бизнес-риски

| Риск | Последствие | Решение |
|------|-------------|---------|
| Overselling | Отмена заказа | `primary` для stock |
| Потеря товаров в корзине | Недовольство клиента | `primary` для корзины |
| Устаревший статус | Повторная оплата | `primary` для свежих заказов |

### 5.4. Пример кода

```javascript
// Безопасная проверка stock
async function purchaseProduct(productId, quantity) {
  const session = await mongoose.startSession();
  session.startTransaction();

  const product = await Product.findById(productId)
    .session(session)
    .read('primary');

  if (product.stock < quantity) {
    throw new Error('Недостаточно товара');
  }

  await Product.updateOne(
    { _id: productId, stock: { $gte: quantity } },
    { $inc: { stock: -quantity } },
    { session }
  );

  await session.commitTransaction();
}
```

---

## 6. Миграция на Cassandra

### 6.1. Критерии выбора

| Критерий | Cassandra | MongoDB |
|----------|-----------|---------|
| Паттерн доступа | Key-value, time-series | Ad-hoc queries |
| Консистентность | Eventual OK | Strong required |
| Запись | Высокая throughput | Атомарная |
| Масштабирование | Линейное, без resharding | Resharding при росте |

### 6.2. Решение по миграции

| В Cassandra | Остаётся в MongoDB |
|-------------|-------------------|
| Сессии пользователей | Активные заказы |
| Корзины | Каталог товаров |
| История заказов | Остатки на складе |

См. диаграмму: [migration-architecture.drawio](migration-architecture.drawio)

### Диаграмма архитектуры

См. файл [geo-architecture.drawio](geo-architecture.drawio)

**Структура:**
- **Cassandra** (3 DC: Europe, USA, Asia) — сессии, корзины, история заказов
- **MongoDB** (sharded, primary region) — активные заказы, каталог + остатки, платежи

### 6.3. Обоснование

**Сессии → Cassandra:**
- Каждый запрос обновляет сессию (высокая частота записи)
- Доступ всегда по `session_id` (простой key-value)
- TTL 24 часа (встроенная поддержка)
- Потеря последних секунд некритична

**Корзины → Cassandra:**
- Частые добавления/удаления товаров
- TTL для брошенных корзин
- При checkout читаем с QUORUM

**История заказов → Cassandra:**
- Append-only (не изменяются)
- Терабайты данных за годы
- Простой доступ: «заказы клиента X за период Y»

**Активные заказы → MongoDB:**
- Сложный workflow статусов
- Связь с платежами (транзакции)
- Нельзя потерять/дублировать

**Остатки → MongoDB:**
- Атомарные операции `$inc`
- Race conditions при параллельных покупках
- Strong consistency (риск overselling)

---

## 7. Структуры данных Cassandra

### 7.1. Таблица: user_sessions

```cql
CREATE TABLE user_sessions (
    session_id      TEXT,
    user_id         UUID,
    created_at      TIMESTAMP,
    last_activity   TIMESTAMP,
    ip_address      TEXT,
    user_agent      TEXT,
    cart_id         UUID,
    preferences     MAP<TEXT, TEXT>,

    PRIMARY KEY (session_id)
) WITH default_time_to_live = 86400;  -- TTL 24 часа
```

| Ключ | Значение | Обоснование |
|------|----------|-------------|
| Partition Key | `session_id` | Уникален, равномерное распределение |
| Clustering Key | нет | Одна строка на сессию |

### 7.2. Таблица: shopping_carts

```cql
CREATE TABLE shopping_carts (
    cart_id         UUID,
    user_id         UUID,
    session_id      TEXT,
    product_id      UUID,
    product_name    TEXT,       -- денормализация
    product_price   DECIMAL,    -- денормализация
    quantity        INT,
    added_at        TIMESTAMP,

    PRIMARY KEY (cart_id, product_id)
) WITH default_time_to_live = 604800;  -- TTL 7 дней
```

| Ключ | Значение | Обоснование |
|------|----------|-------------|
| Partition Key | `cart_id` | Все товары корзины вместе |
| Clustering Key | `product_id` | Уникальность товара |

### 7.3. Таблица: orders_by_customer

```cql
CREATE TABLE orders_by_customer (
    customer_id     UUID,
    order_date      DATE,
    order_id        UUID,
    order_time      TIMESTAMP,
    status          TEXT,
    total_amount    DECIMAL,
    items_count     INT,

    PRIMARY KEY ((customer_id), order_date, order_id)
) WITH CLUSTERING ORDER BY (order_date DESC, order_id DESC);
```

| Ключ | Значение | Обоснование |
|------|----------|-------------|
| Partition Key | `customer_id` | Все заказы клиента вместе |
| Clustering Key | `order_date DESC` | Сортировка по дате |

**Риск:** hot partition для VIP-клиентов с тысячами заказов.

**Решение:** bucketing по году:
```cql
PRIMARY KEY ((customer_id, year), order_date, order_id)
```

### 7.4. Сводная таблица ключей

| Таблица | Partition Key | Clustering Key | Размер партиции |
|---------|---------------|----------------|-----------------|
| `user_sessions` | `session_id` | — | 1 строка |
| `shopping_carts` | `cart_id` | `product_id` | ~10-50 строк |
| `orders_by_customer` | `customer_id` | `order_date, order_id` | ~100-1000 строк |
| `orders_by_customer_year` | `customer_id, year` | `order_date, order_id` | ~10-100 строк |
| `order_items` | `order_id` | `item_index` | ~5-20 строк |

---

## 8. Стратегии целостности данных Cassandra

### 8.1. Обзор стратегий

| Стратегия | Когда работает | Latency | Гарантия |
|-----------|---------------|---------|----------|
| Hinted Handoff | Узел временно недоступен | Низкий | Слабая |
| Read Repair | При чтении | Средний | Средняя |
| Anti-Entropy Repair | Фоновый процесс | Высокий | Сильная |

### 8.2. Hinted Handoff

При недоступности узла coordinator сохраняет hint и передаёт данные, когда узел вернётся.

```yaml
# cassandra.yaml
hinted_handoff_enabled: true
max_hint_window_in_ms: 10800000  # 3 часа
```

### 8.3. Read Repair

При чтении coordinator сравнивает версии на репликах и обновляет устаревшие.

```cql
ALTER TABLE user_sessions WITH read_repair = 'BLOCKING';
```

### 8.4. Anti-Entropy Repair

Фоновый процесс сравнения Merkle trees:

```bash
nodetool repair shop_keyspace
nodetool repair -pr shop_keyspace  # инкрементальный
```

### 8.5. Выбор стратегий по таблицам

| Таблица | Hinted Handoff | Read Repair | Anti-Entropy | Write CL | Read CL |
|---------|---------------|-------------|--------------|----------|---------|
| `user_sessions` | Да | BLOCKING | Редко | ONE | ONE |
| `shopping_carts` | Да | BLOCKING | Еженедельно | LOCAL_QUORUM | ONE* |
| `orders_by_customer` | Да | BLOCKING | Еженедельно | QUORUM | ONE |

*QUORUM при checkout

---

## 9. Сравнение масштабирования

### MongoDB: добавление 4-го шарда (Range-Based Sharding)

| Шард | До | После | Перемещение |
|------|-----|-------|-------------|
| Shard1 | 33% | 25% | отдаёт 8% |
| Shard2 | 33% | 25% | отдаёт 8% |
| Shard3 | 33% | 25% | отдаёт 8% |
| Shard4 | 0% | 25% | получает 24% |

**Итого:** перемещается ~24% данных. Время: часы. Latency spike.

### Cassandra: добавление 4-го узла (Consistent Hashing)

| Узел | До | После | Перемещение |
|------|-----|-------|-------------|
| Node1 | 33% | 25% | отдаёт 8% соседу |
| Node2 | 33% | 33% | без изменений |
| Node3 | 33% | 33% | без изменений |
| Node4 | 0% | 8% | получает от Node1 |

**Итого:** перемещается ~8% данных. Время: минуты. Минимальное влияние.

См. диаграмму: [geo-architecture.drawio](geo-architecture.drawio)

---

## 10. Метрики мониторинга

### 10.1. Сводная таблица

| Категория | Метрика | Источник | Warning | Critical |
|-----------|---------|----------|---------|----------|
| **Система** | CPU | node_exporter | > 70% | > 90% |
| | Memory | node_exporter | > 80% | > 95% |
| | Disk I/O | iostat | > 30% | > 50% |
| **MongoDB** | Query rate | opcounters | 3× среднего | 5× среднего |
| | Write queue | globalLock | > 50 | > 100 |
| | Latency p99 | opLatencies | > 100ms | > 500ms |
| | Replication lag | rs.status() | > 5s | > 30s |
| **Шардинг** | Chunk imbalance | config.chunks | > 20% | > 50% |
| | Jumbo chunks | config.chunks | > 0 | > 10 |
| **Cassandra** | Read latency p99 | JMX | > 50ms | > 200ms |
| | Write latency p99 | JMX | > 20ms | > 100ms |
| | Compaction pending | nodetool | > 50 | > 200 |

### 10.2. Prometheus alerts

```yaml
groups:
  - name: mongodb-sharding
    rules:
      - alert: ChunkImbalance
        expr: max(mongodb_chunks_total) / min(mongodb_chunks_total) > 1.3
        for: 30m
        labels:
          severity: warning

      - alert: ShardHighLoad
        expr: rate(mongodb_op_counters_total{type="query"}[5m]) > 10000
        for: 10m
        labels:
          severity: warning

      - alert: ReplicationLag
        expr: mongodb_replset_member_replication_lag_seconds > 10
        for: 5m
        labels:
          severity: critical
```

### 10.3. Действия при проблемах

| Проблема | Действия |
|----------|----------|
| Горячий шард | Включить балансировщик, перенаправить reads на secondary |
| Высокий replication lag | Проверить сеть, добавить secondary, уменьшить write concern |
| Jumbo chunks | Разделить через `sh.splitAt()`, пересмотреть шард-ключ |
| Cassandra compaction backlog | Увеличить `compaction_throughput_mb_per_sec` |


